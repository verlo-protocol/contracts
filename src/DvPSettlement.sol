// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IKYCRegistry {
    function isVerified(address wallet) external view returns (bool);
}

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface ISecurityToken {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function pricePerToken() external view returns (uint256);
    function calculateFee(uint256 amount, bool isVRLHolder) external pure returns (uint256);
}

contract DvPSettlement {

    address public admin;
    IKYCRegistry public immutable kycRegistry;
    address public immutable usdcAddress;
    address public vrlToken;
    address public feeCollector;
    bool public paused;
    uint256 private _reentrancyStatus;
    uint256 public totalVolumeSettled;
    uint256 public totalFeesCollected;
    uint256 public vrlDiscountThreshold;
    uint256 public tradeCount;

    struct TradeRecord {
        uint256 tradeId;
        address buyer;
        address seller;
        address securityToken;
        uint256 tokenAmount;
        uint256 usdcAmount;
        uint256 feeAmount;
        uint256 timestamp;
        bool vrlDiscount;
    }

    mapping(uint256 => TradeRecord) public trades;
    mapping(address => uint256[]) public tradesByWallet;

    event TradeSettled(
        uint256 indexed tradeId,
        address indexed buyer,
        address indexed seller,
        address securityToken,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint256 feeAmount,
        bool vrlDiscount,
        uint256 timestamp
    );
    event TradingPaused(uint256 timestamp);
    event TradingResumed(uint256 timestamp);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event VRLTokenSet(address indexed vrlToken, uint256 threshold);
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Verlo: caller is not admin");
        _;
    }

    modifier notPaused() {
        require(!paused, "Verlo: settlement is paused");
        _;
    }

    modifier onlyVerified(address wallet) {
        require(kycRegistry.isVerified(wallet), "Verlo: wallet not KYC verified");
        _;
    }

    modifier nonReentrant() {
        require(_reentrancyStatus == 1, "Verlo: reentrant call blocked");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    constructor(
        address _kycRegistry,
        address _usdcAddress,
        address _feeCollector
    ) {
        require(_kycRegistry != address(0),  "Verlo: KYC registry cannot be zero");
        require(_usdcAddress != address(0),  "Verlo: USDC address cannot be zero");
        require(_feeCollector != address(0), "Verlo: fee collector cannot be zero");

        admin             = msg.sender;
        kycRegistry       = IKYCRegistry(_kycRegistry);
        usdcAddress       = _usdcAddress;
        feeCollector      = _feeCollector;
        paused            = false;
        _reentrancyStatus = 1;
    }

    function settleTradeAtomic(
        address seller,
        address securityToken,
        uint256 tokenAmount,
        uint256 usdcAmount
    )
        external
        nonReentrant
        notPaused
        onlyVerified(msg.sender)
        onlyVerified(seller)
    {
        address buyer = msg.sender;

        require(seller != address(0), "Verlo: invalid seller");
        require(seller != buyer, "Verlo: buyer and seller cannot be same");
        require(tokenAmount > 0, "Verlo: token amount must be greater than 0");
        require(usdcAmount > 0, "Verlo: USDC amount must be greater than 0");

        bool hasVRLDiscount = _checkVRLDiscount(buyer);
        uint256 feeBps     = hasVRLDiscount ? 20 : 30;
        uint256 feeAmount  = (usdcAmount * feeBps) / 10000;
        uint256 sellerGets = usdcAmount - feeAmount;

        IERC20 usdc = IERC20(usdcAddress);
        require(usdc.balanceOf(buyer) >= usdcAmount, "Verlo: insufficient USDC balance");
        require(usdc.allowance(buyer, address(this)) >= usdcAmount, "Verlo: insufficient USDC allowance - approve this contract first");

        ISecurityToken sToken = ISecurityToken(securityToken);
        require(sToken.balanceOf(seller) >= tokenAmount, "Verlo: seller has insufficient tokens");
        require(sToken.allowance(seller, address(this)) >= tokenAmount, "Verlo: seller must approve this contract");

        tradeCount += 1;
        uint256 tradeId = tradeCount;

        trades[tradeId] = TradeRecord({
            tradeId       : tradeId,
            buyer         : buyer,
            seller        : seller,
            securityToken : securityToken,
            tokenAmount   : tokenAmount,
            usdcAmount    : usdcAmount,
            feeAmount     : feeAmount,
            timestamp     : block.timestamp,
            vrlDiscount   : hasVRLDiscount
        });

        tradesByWallet[buyer].push(tradeId);
        tradesByWallet[seller].push(tradeId);

        totalVolumeSettled += usdcAmount;
        totalFeesCollected += feeAmount;

        emit TradeSettled(
            tradeId,
            buyer,
            seller,
            securityToken,
            tokenAmount,
            usdcAmount,
            feeAmount,
            hasVRLDiscount,
            block.timestamp
        );

        bool usdcToSeller = usdc.transferFrom(buyer, seller, sellerGets);
        require(usdcToSeller, "Verlo: USDC transfer to seller failed");

        bool usdcFee = usdc.transferFrom(buyer, feeCollector, feeAmount);
        require(usdcFee, "Verlo: USDC fee transfer failed");

        bool tokenTransfer = sToken.transferFrom(seller, buyer, tokenAmount);
        require(tokenTransfer, "Verlo: security token transfer failed");
    }

    function _checkVRLDiscount(address wallet) internal view returns (bool) {
        if (vrlToken == address(0)) return false;
        if (vrlDiscountThreshold == 0) return false;
        return IERC20(vrlToken).balanceOf(wallet) >= vrlDiscountThreshold;
    }

    function setVRLToken(address _vrlToken, uint256 _threshold) external onlyAdmin {
        require(_vrlToken != address(0), "Verlo: VRL token cannot be zero");
        vrlToken             = _vrlToken;
        vrlDiscountThreshold = _threshold;
        emit VRLTokenSet(_vrlToken, _threshold);
    }

    function pauseSettlement() external onlyAdmin {
        paused = true;
        emit TradingPaused(block.timestamp);
    }

    function resumeSettlement() external onlyAdmin {
        paused = false;
        emit TradingResumed(block.timestamp);
    }

    function updateFeeCollector(address newCollector) external onlyAdmin {
        require(newCollector != address(0), "Verlo: invalid address");
        emit FeeCollectorUpdated(feeCollector, newCollector);
        feeCollector = newCollector;
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Verlo: invalid address");
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }

    function getTradeDetails(uint256 tradeId) external view returns (TradeRecord memory) {
        require(tradeId > 0 && tradeId <= tradeCount, "Verlo: invalid trade ID");
        return trades[tradeId];
    }

    function getWalletTrades(address wallet) external view returns (uint256[] memory) {
        return tradesByWallet[wallet];
    }

    function getPlatformStats() external view returns (uint256, uint256, uint256, bool) {
        return (tradeCount, totalVolumeSettled, totalFeesCollected, paused);
    }

    function previewFee(uint256 usdcAmount, address wallet) external view returns (uint256 feeAmount, bool hasDiscount) {
        hasDiscount = _checkVRLDiscount(wallet);
        uint256 bps = hasDiscount ? 20 : 30;
        feeAmount   = (usdcAmount * bps) / 10000;
    }
}
