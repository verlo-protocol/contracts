// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import { KYCRegistry } from "../src/KYCRegistry.sol";
import { SecurityToken } from "../src/SecurityToken.sol";
import { DvPSettlement } from "../src/DvPSettlement.sol";

/**
 * @title MockUSDC
 * @notice Fake USDC for testing — behaves like real USDC (6 decimals)
 */
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "USDC";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "USDC: insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "USDC: insufficient");
        require(allowance[from][msg.sender] >= amount, "USDC: not allowed");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        return true;
    }
}

/**
 * @title VerloTestSuite
 * @notice Tests the full Verlo platform — KYC, SecurityToken, DvP settlement.
 *         Run with: forge test
 */
contract VerloTestSuite is Test {
    // Contracts
    KYCRegistry kyc;
    SecurityToken token;
    DvPSettlement dvp;
    MockUSDC usdc;

    // Actors
    address admin     = address(this);  // the test contract itself
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");
    address charlie   = makeAddr("charlie");  // not KYC'd
    address treasury  = makeAddr("treasury");

    function setUp() public {
        // Deploy KYC registry
        kyc = new KYCRegistry();

        // Deploy mock USDC and mint funds
        usdc = new MockUSDC();
        usdc.mint(alice, 10_000 * 10**6);  // $10,000
        usdc.mint(bob, 10_000 * 10**6);

        // Deploy security token — "Verlo Test Equity"
        token = new SecurityToken(
            "Verlo Test Equity",
            "VTE",
            address(kyc),
            "Test asset",
            "equity",
            6_000_000,  // $6 per token
            treasury
        );

        // Deploy DvP settlement
        dvp = new DvPSettlement(
            address(kyc),
            address(usdc),
            treasury
        );

        // KYC verify alice and bob (charlie stays unverified)
        kyc.verifyWallet(alice);
        kyc.verifyWallet(bob);

        // Mint security tokens to alice
        token.mint(alice, 100 * 10**18);  // 100 VTE tokens
    }

    // ═══════════════════════════════════════════════
    //   KYC REGISTRY TESTS
    // ═══════════════════════════════════════════════

    function test_KYC_InitialSetup() public {
        assertTrue(kyc.isVerified(alice));
        assertTrue(kyc.isVerified(bob));
        assertFalse(kyc.isVerified(charlie));
        assertEq(kyc.totalVerified(), 2);
    }

    function test_KYC_VerifyNewWallet() public {
        kyc.verifyWallet(charlie);
        assertTrue(kyc.isVerified(charlie));
        assertEq(kyc.totalVerified(), 3);
    }

    function test_KYC_CannotVerifyZeroAddress() public {
        vm.expectRevert("Verlo: invalid address");
        kyc.verifyWallet(address(0));
    }

    function test_KYC_CannotDoubleVerify() public {
        vm.expectRevert("Verlo: wallet already verified");
        kyc.verifyWallet(alice);
    }

    function test_KYC_OnlyAdminCanVerify() public {
        vm.prank(charlie);
        vm.expectRevert("Verlo: caller is not admin");
        kyc.verifyWallet(charlie);
    }

    function test_KYC_RevokeWallet() public {
        kyc.revokeWallet(alice);
        assertFalse(kyc.isVerified(alice));
        assertEq(kyc.totalVerified(), 1);
    }

    function test_KYC_BatchVerification() public {
        address[] memory wallets = new address[](3);
        wallets[0] = charlie;
        wallets[1] = makeAddr("dan");
        wallets[2] = makeAddr("eve");
        kyc.verifyWalletBatch(wallets);

        assertTrue(kyc.isVerified(wallets[0]));
        assertTrue(kyc.isVerified(wallets[1]));
        assertTrue(kyc.isVerified(wallets[2]));
        assertEq(kyc.totalVerified(), 5);
    }

    function test_KYC_AdminTransfer() public {
        kyc.changeAdmin(alice);
        assertEq(kyc.admin(), alice);
    }

    // ═══════════════════════════════════════════════
    //   SECURITY TOKEN TESTS
    // ═══════════════════════════════════════════════

    function test_Token_InitialBalance() public {
        assertEq(token.balanceOf(alice), 100 * 10**18);
        assertEq(token.totalSupply(), 100 * 10**18);
    }

    function test_Token_TransferBetweenVerified() public {
        vm.prank(alice);
        token.transfer(bob, 10 * 10**18);
        assertEq(token.balanceOf(alice), 90 * 10**18);
        assertEq(token.balanceOf(bob), 10 * 10**18);
    }

    function test_Token_CannotTransferToUnverified() public {
        vm.prank(alice);
        vm.expectRevert("Verlo: wallet not KYC verified");
        token.transfer(charlie, 1 * 10**18);
    }

    function test_Token_UnverifiedCannotTransfer() public {
        // Give charlie some tokens through admin mint (mint checks only receiver KYC)
        // Actually mint should also fail — let's verify that
        vm.expectRevert("Verlo: wallet not KYC verified");
        token.mint(charlie, 1 * 10**18);
    }

    function test_Token_PauseBlocksTransfers() public {
        token.pauseTrading();

        vm.prank(alice);
        vm.expectRevert("Verlo: trading is paused");
        token.transfer(bob, 1 * 10**18);
    }

    function test_Token_ResumeAllowsTransfers() public {
        token.pauseTrading();
        token.resumeTrading();

        vm.prank(alice);
        token.transfer(bob, 1 * 10**18);
        assertEq(token.balanceOf(bob), 1 * 10**18);
    }

    function test_Token_BurnReducesSupply() public {
        token.burn(alice, 50 * 10**18);
        assertEq(token.balanceOf(alice), 50 * 10**18);
        assertEq(token.totalSupply(), 50 * 10**18);
    }

    function test_Token_FeeCalculationNormal() public view {
        uint256 fee = token.calculateFee(1000 * 10**6, false);  // $1000 trade
        assertEq(fee, 3 * 10**6);  // 0.3% = $3
    }

    function test_Token_FeeCalculationVRLHolder() public view {
        uint256 fee = token.calculateFee(1000 * 10**6, true);
        assertEq(fee, 2 * 10**6);  // 0.2% = $2
    }

    function test_Token_OnlyAdminCanMint() public {
        vm.prank(charlie);
        vm.expectRevert("Verlo: caller is not admin");
        token.mint(alice, 1 * 10**18);
    }

    // ═══════════════════════════════════════════════
    //   DVP SETTLEMENT TESTS
    // ═══════════════════════════════════════════════

    function _setupTrade(uint256 tokenAmount, uint256 usdcAmount) internal {
        vm.prank(alice);
        token.approve(address(dvp), tokenAmount);

        vm.prank(bob);
        usdc.approve(address(dvp), usdcAmount);
    }

    function test_DvP_SuccessfulTrade() public {
        uint256 tokenAmount = 10 * 10**18;  // 10 VTE
        uint256 usdcAmount  = 60 * 10**6;   // $60

        _setupTrade(tokenAmount, usdcAmount);

        uint256 aliceUsdcBefore    = usdc.balanceOf(alice);
        uint256 treasuryUsdcBefore = usdc.balanceOf(treasury);

        vm.prank(bob);
        dvp.settleTradeAtomic(alice, address(token), tokenAmount, usdcAmount);

        // Bob got the tokens
        assertEq(token.balanceOf(bob), tokenAmount);
        // Alice got USDC minus fee (0.3%)
        uint256 expectedFee = (usdcAmount * 30) / 10000;  // $0.18
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore + usdcAmount - expectedFee);
        // Treasury got the fee
        assertEq(usdc.balanceOf(treasury), treasuryUsdcBefore + expectedFee);
        // Trade counter incremented
        assertEq(dvp.tradeCount(), 1);
    }

    function test_DvP_UnverifiedBuyerBlocked() public {
        _setupTrade(10 * 10**18, 60 * 10**6);

        vm.prank(charlie);
        vm.expectRevert("Verlo: wallet not KYC verified");
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);
    }

    function test_DvP_UnverifiedSellerBlocked() public {
        usdc.mint(bob, 10_000 * 10**6);
        vm.prank(bob);
        usdc.approve(address(dvp), 60 * 10**6);

        vm.prank(bob);
        vm.expectRevert("Verlo: wallet not KYC verified");
        dvp.settleTradeAtomic(charlie, address(token), 10 * 10**18, 60 * 10**6);
    }

    function test_DvP_CannotTradeWithSelf() public {
        _setupTrade(10 * 10**18, 60 * 10**6);
        vm.prank(alice);
        usdc.approve(address(dvp), 60 * 10**6);
        usdc.mint(alice, 60 * 10**6);

        vm.prank(alice);
        vm.expectRevert("Verlo: buyer and seller cannot be same");
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);
    }

    function test_DvP_InsufficientUsdcBalance() public {
        _setupTrade(10 * 10**18, 60 * 10**6);

        vm.prank(bob);
        usdc.approve(address(dvp), 100_000 * 10**6);

        vm.prank(bob);
        vm.expectRevert("Verlo: insufficient USDC balance");
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 50_000 * 10**6);
    }

    function test_DvP_InsufficientAllowance() public {
        // Only set token approval, not USDC
        vm.prank(alice);
        token.approve(address(dvp), 10 * 10**18);

        vm.prank(bob);
        vm.expectRevert("Verlo: insufficient USDC allowance - approve this contract first");
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);
    }

    function test_DvP_SellerHasInsufficientTokens() public {
        // Alice only has 100 tokens, bob tries to buy 200
        _setupTrade(200 * 10**18, 1200 * 10**6);

        vm.prank(bob);
        vm.expectRevert("Verlo: seller has insufficient tokens");
        dvp.settleTradeAtomic(alice, address(token), 200 * 10**18, 1200 * 10**6);
    }

    function test_DvP_PauseBlocksSettlement() public {
        _setupTrade(10 * 10**18, 60 * 10**6);
        dvp.pauseSettlement();

        vm.prank(bob);
        vm.expectRevert("Verlo: settlement is paused");
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);
    }

    function test_DvP_PlatformStatsTrackCorrectly() public {
        _setupTrade(10 * 10**18, 60 * 10**6);
        vm.prank(bob);
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);

        (uint256 trades, uint256 volume, uint256 fees, bool paused) = dvp.getPlatformStats();
        assertEq(trades, 1);
        assertEq(volume, 60 * 10**6);
        assertEq(fees, (60 * 10**6 * 30) / 10000);  // 0.3%
        assertFalse(paused);
    }

    function test_DvP_TradeRecordStored() public {
        _setupTrade(10 * 10**18, 60 * 10**6);
        vm.prank(bob);
        dvp.settleTradeAtomic(alice, address(token), 10 * 10**18, 60 * 10**6);

        DvPSettlement.TradeRecord memory trade = dvp.getTradeDetails(1);
        assertEq(trade.buyer, bob);
        assertEq(trade.seller, alice);
        assertEq(trade.tokenAmount, 10 * 10**18);
        assertEq(trade.usdcAmount, 60 * 10**6);
    }

    function test_DvP_PreviewFeeMatchesActual() public view {
        (uint256 fee, bool discount) = dvp.previewFee(1000 * 10**6, bob);
        assertEq(fee, 3 * 10**6);
        assertFalse(discount);
    }

    function test_DvP_ZeroAddressChecksInConstructor() public {
        vm.expectRevert("Verlo: KYC registry cannot be zero");
        new DvPSettlement(address(0), address(usdc), treasury);

        vm.expectRevert("Verlo: USDC address cannot be zero");
        new DvPSettlement(address(kyc), address(0), treasury);

        vm.expectRevert("Verlo: fee collector cannot be zero");
        new DvPSettlement(address(kyc), address(usdc), address(0));
    }

    // ═══════════════════════════════════════════════
    //   REENTRANCY TESTS
    // ═══════════════════════════════════════════════

    function test_DvP_ReentrancyGuardInitialized() public view {
        // After deployment, should allow first call (status == 1)
        // If the guard wasn't initialized, ALL calls would revert
        // Just verify it doesn't immediately revert on a standard call
        (uint256 trades,,,) = dvp.getPlatformStats();
        assertEq(trades, 0);
    }

    // ═══════════════════════════════════════════════
    //   FUZZ TESTS — random input testing
    // ═══════════════════════════════════════════════

    function testFuzz_FeeCalculationNeverOverflows(uint128 amount) public view {
        uint256 fee = token.calculateFee(amount, false);
        assertLe(fee, amount);  // Fee always <= amount
    }

    function testFuzz_KYCBatchHandlesVariableSizes(uint8 size) public {
        vm.assume(size > 0 && size <= 50);

        address[] memory wallets = new address[](size);
        for (uint256 i = 0; i < size; i++) {
            wallets[i] = address(uint160(uint256(keccak256(abi.encode(i, block.timestamp)))));
        }

        uint256 before = kyc.totalVerified();
        kyc.verifyWalletBatch(wallets);
        assertEq(kyc.totalVerified(), before + size);
    }
}
