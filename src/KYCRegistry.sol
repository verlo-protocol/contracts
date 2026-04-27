// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title KYCRegistry
 * @author Verlo Platform
 * @notice This contract keeps track of which wallets have passed KYC.
 *         Only verified wallets can trade on Verlo.
 *         Only the admin (you) can approve or remove wallets.
 */

contract KYCRegistry {


    // --- State ---


    /// @notice The owner of this contract (you — the Verlo founder)
    address public admin;

    /// @notice Maps each wallet address to their KYC status
    /// true  = verified, can trade on Verlo
    /// false = not verified, blocked from trading
    mapping(address => bool) public isVerified;

    /// @notice When each wallet was verified (Unix timestamp)
    mapping(address => uint256) public verifiedAt;

    /// @notice Total number of verified users
    uint256 public totalVerified;



    // --- Events ---


    /// @notice Fired when a wallet is approved
    event WalletVerified(address indexed wallet, uint256 timestamp);

    /// @notice Fired when a wallet is removed
    event WalletRevoked(address indexed wallet, uint256 timestamp);

    /// @notice Fired when admin transfers ownership
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);



    // --- Modifiers ---


    /// @notice Only the admin wallet can call certain functions
    modifier onlyAdmin() {
        require(msg.sender == admin, "Verlo: caller is not admin");
        _;
    }



    // --- Constructor ---


    /**
     * @notice Runs once when contract is deployed
     * @dev Replace YOUR_WALLET_ADDRESS_HERE with your 0x... address
     */
    constructor() {
        admin = msg.sender; // <-- paste your 0x address here
    }



    // --- Admin functions ---


    /**
     * @notice Approve a single wallet — they passed KYC
     * @param wallet The user's wallet address to approve
     */
    function verifyWallet(address wallet) external onlyAdmin {
        require(wallet != address(0), "Verlo: invalid address");
        require(!isVerified[wallet], "Verlo: wallet already verified");

        isVerified[wallet] = true;
        verifiedAt[wallet] = block.timestamp;
        totalVerified += 1;

        emit WalletVerified(wallet, block.timestamp);
    }

    /**
     * @notice Approve multiple wallets at once (saves gas)
     * @param wallets Array of wallet addresses to approve
     */
    function verifyWalletBatch(address[] calldata wallets) external onlyAdmin {
    uint256 newCount = 0;
    uint256 len = wallets.length;
    for (uint256 i = 0; i < len; i++) {
        address wallet = wallets[i];
        if (wallet != address(0) && !isVerified[wallet]) {
            isVerified[wallet] = true;
            verifiedAt[wallet] = block.timestamp;
            unchecked { newCount++; }
            emit WalletVerified(wallet, block.timestamp);
        }
    }
    if (newCount > 0) {
        totalVerified += newCount;
    }
}

    /**
     * @notice Remove a wallet's KYC approval (e.g. fraud detected)
     * @param wallet The wallet address to revoke
     */
    function revokeWallet(address wallet) external onlyAdmin {
        require(isVerified[wallet], "Verlo: wallet not verified");

        isVerified[wallet] = false;
        verifiedAt[wallet] = 0;
        totalVerified -= 1;

        emit WalletRevoked(wallet, block.timestamp);
    }

    /**
     * @notice Transfer admin rights to a new address
     * @param newAdmin The new admin wallet address
     */
    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Verlo: invalid address");
        emit AdminChanged(admin, newAdmin);
        admin = newAdmin;
    }



    // --- View functions ---


    /**
     * @notice Check if a wallet is verified
     * @param wallet The wallet to check
     * @return true if verified, false if not
     */
    function checkVerified(address wallet) external view returns (bool) {
        return isVerified[wallet];
    }

    /**
     * @notice Check multiple wallets at once
     * @param wallets Array of wallets to check
     * @return Array of booleans matching each wallet's status
     */
    function checkVerifiedBatch(address[] calldata wallets)
        external
        view
        returns (bool[] memory)
    {
        bool[] memory results = new bool[](wallets.length);
        for (uint256 i = 0; i < wallets.length; i++) {
            results[i] = isVerified[wallets[i]];
        }
        return results;
    }
}
