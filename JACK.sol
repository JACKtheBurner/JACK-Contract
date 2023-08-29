// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;
import './ERC20.sol';
import './Ownable.sol';
import './IPancakeFactory.sol';
import './IPulseXRouter.sol';
import './IJACKBurnPool.sol';
import './IXENCrypto.sol';
import './ReentrancyGuard.sol';


interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IBurnRedeemable {
    function onTokenBurned(address user, uint256 amount) external;
}

contract JACK is ERC20, Ownable, IERC165, IBurnRedeemable, ReentrancyGuard {

    IPulseXRouter02 public immutable router;
    address public immutable lpPair;
    address public immutable xenAddress;
    uint256 public burntAmount;
    uint256 public immutable taxFee;

    mapping(address => uint256) public userAccumulatedJack;
    mapping(address => uint256) public userBurntXen;
    mapping(address => bool) public excludedFromFee;
    event AccumulatedFee(address account, uint256 amount);
    event SwappedFee(address token, uint256 amount);
    event XENTokenBurnt(address user, uint256 amount);

    bytes4 private constant _INTERFACE_ID_IBURNREDEEMABLE = type(IBurnRedeemable).interfaceId;

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == _INTERFACE_ID_IBURNREDEEMABLE || interfaceId == type(IERC165).interfaceId;
    }


    function onTokenBurned(address user, uint256 amount) external override {
        emit XENTokenBurnt(user, amount);
    }


    constructor() ERC20('JACK', 'JACK') {
        xenAddress = 0x8a7FDcA264e87b6da72D000f22186B4403081A2a;
        IPulseXRouter02 _router = IPulseXRouter02(0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02); 
        
        router = _router;
        lpPair = IPancakeFactory(router.factory()).createPair(address(this), router.WPLS());
        burntAmount = 0;
        taxFee = 100;
        excludedFromFee[msg.sender] = true;
        excludedFromFee[address(router)] = true;
        excludedFromFee[address(this)] = true;
        //approve maximum amount of XEN for the JACK contract
        IXENCrypto xenTokenInstance = IXENCrypto(xenAddress);
        uint256 maxAmount = type(uint256).max;  // max possible value for uint256
        xenTokenInstance.approve(xenAddress, maxAmount);
        // mint the initial supply
        _mint(msg.sender, 1665000000000 * 10 ** 18);
        //_mint(address(this), 435000000000 * 10 ** 18);
    }


    function transferOwnership(address newOwner) public override onlyOwner {
        excludedFromFee[newOwner] = true;
        super.transferOwnership(newOwner);
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), 'ERC20: transfer from the zero address');
        require(to != address(0), 'ERC20: transfer to the zero address');
        uint256 fee = amount / taxFee; // This represents the 1% fee tax
        if (from == lpPair && !excludedFromFee[to]) {
            super._transfer(from, to, amount - fee);
            super._transfer(from, address(this), fee);
            // record the amount of xen bought
            userAccumulatedJack[to] += fee;
            emit AccumulatedFee(from, fee);
        } else if (to == lpPair && !excludedFromFee[from]) {
            super._transfer(from, to, amount - fee);
            super._transfer(from, address(this), fee);
            // record the amount of xen bought
            userAccumulatedJack[from] += fee;
            emit AccumulatedFee(from, fee);
        } else {
            super._transfer(from, to, amount);
        }
    }

    function burn() public nonReentrant returns (uint256){
        require(userAccumulatedJack[msg.sender] > 0, 'JACK: You have no JACK to burn');

        uint256 jackAmount = userAccumulatedJack[msg.sender];
        address swapToken = xenAddress;
        uint256 outputAmount;
        uint256[] memory amounts;
        _approve(address(this), address(router), jackAmount);

        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = router.WPLS();
        path[2] = swapToken;
        amounts = router.swapExactTokensForTokens(jackAmount, 0, path, address(this), block.timestamp);
        outputAmount = amounts[2];

        emit SwappedFee(swapToken, outputAmount);

        // burn the xen on behalf of the user
        uint256 amountBurnt = burnXen(msg.sender, outputAmount);

        return amountBurnt;
    }

    function burnXen(address user, uint256 amount) internal returns (uint256){
        if(amount > 0){
            IXENCrypto xenTokenInstance = IXENCrypto(xenAddress);
            // send the Xen to the user
            xenTokenInstance.transfer(user, amount);
            // burn the xen on behalf of the user
            xenTokenInstance.burn(user, amount);
            // update the user stats
            userAccumulatedJack[user] = 0;
            userBurntXen[user] += amount;
            // update state
            burntAmount += amount;

            return amount;
        }
        return 0;
    }

    function getXenBalance(address userAddress) external view returns (uint256) {
        IERC20 tokenInstance = IERC20(xenAddress);
        return tokenInstance.balanceOf(userAddress);
    }

    // get X1 allocation
    function getX1Allocation(address userAddress) external view returns (uint256) {
        IXENCrypto xenTokenInstance = IXENCrypto(xenAddress);
        return xenTokenInstance.userBurns(userAddress);
    }

    // this function will shouw how much XEN you get when you swap JACK to XEN
    function getJackToXenOutput(uint256 amountIn) external view returns (uint256) {
        uint256 outputAmount;
        uint256[] memory amounts;
        address[] memory path = new address[](3);
        path[0] = address(this);
        path[1] = router.WPLS();
        path[2] = xenAddress;
        amounts = router.getAmountsOut(amountIn, path);
        outputAmount = amounts[2];
        return outputAmount;
    }

     // this function will shouw how much XEN the user can burn
    function getXenUserCanBurn() external view returns (uint256) {
        if (userAccumulatedJack[msg.sender] > 0) {
            uint256 amountIn = userAccumulatedJack[msg.sender];
            uint256 outputAmount;
            uint256[] memory amounts;
            address[] memory path = new address[](3);
            path[0] = address(this);
            path[1] = router.WPLS();
            path[2] = xenAddress;
            amounts = router.getAmountsOut(amountIn, path);
            outputAmount = amounts[2];
            return outputAmount;
        }
        return 0;
    }

    function getUserJackAccumulated() external view returns (uint256) {
        return userAccumulatedJack[msg.sender];
    }

    function getUserXenBurnt() external view returns (uint256) {
        return userBurntXen[msg.sender];
    }
}
