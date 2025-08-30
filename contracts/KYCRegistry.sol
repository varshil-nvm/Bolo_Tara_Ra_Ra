// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title KYCRegistry
 * @dev Manages KYC (Know Your Customer) status for users in the Green Hydrogen Credit system
 * Only authorized certifiers can update KYC status
 */
contract KYCRegistry is AccessControl {
    enum KYCStatus {
        Unverified,  // Default status
        Verified,    // KYC completed and approved
        Revoked      // KYC revoked/suspended
    }
    
    // Role definitions
    bytes32 public constant CERTIFIER_ROLE = keccak256("CERTIFIER_ROLE");
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");
    
    // KYC data structure
    struct KYCData {
        KYCStatus status;
        uint256 verifiedAt;     // Timestamp when verified
        uint256 expiresAt;      // Expiration timestamp (0 = no expiry)
        address certifier;      // Who verified this KYC
        string ipfsHash;        // IPFS hash of KYC documents (optional)
        string reason;          // Reason for status change
    }
    
    // State variables
    mapping(address => KYCData) private kycRecords;
    mapping(address => bool) public registeredUsers;
    
    address[] public userList;
    uint256 public totalRegisteredUsers;
    
    // Events
    event KYCStatusUpdated(
        address indexed user,
        KYCStatus indexed newStatus,
        address indexed certifier,
        string reason
    );
    
    event UserRegistered(address indexed user, uint256 timestamp);
    event KYCExpired(address indexed user, uint256 timestamp);
    
    /**
     * @dev Constructor - sets up roles
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CERTIFIER_ROLE, msg.sender);
        _grantRole(REGULATOR_ROLE, msg.sender);
    }
    
    /**
     * @dev Register a new user in the system
     * Anyone can register, but KYC verification requires a certifier
     */
    function registerUser() external {
        require(!registeredUsers[msg.sender], "User already registered");
        
        registeredUsers[msg.sender] = true;
        userList.push(msg.sender);
        totalRegisteredUsers++;
        
        // Initialize with unverified status
        kycRecords[msg.sender] = KYCData({
            status: KYCStatus.Unverified,
            verifiedAt: 0,
            expiresAt: 0,
            certifier: address(0),
            ipfsHash: "",
            reason: "Initial registration"
        });
        
        emit UserRegistered(msg.sender, block.timestamp);
        emit KYCStatusUpdated(msg.sender, KYCStatus.Unverified, address(0), "Initial registration");
    }
    
    /**
     * @dev Verify a user's KYC (only certifiers)
     * @param user Address to verify
     * @param expiryDuration Duration in seconds (0 for no expiry)
     * @param ipfsHash IPFS hash of verification documents
     * @param reason Reason for verification
     */
    function verifyKYC(
        address user,
        uint256 expiryDuration,
        string memory ipfsHash,
        string memory reason
    ) external onlyRole(CERTIFIER_ROLE) {
        require(registeredUsers[user], "User not registered");
        require(kycRecords[user].status != KYCStatus.Verified, "User already verified");
        
        uint256 expiresAt = expiryDuration > 0 ? block.timestamp + expiryDuration : 0;
        
        kycRecords[user] = KYCData({
            status: KYCStatus.Verified,
            verifiedAt: block.timestamp,
            expiresAt: expiresAt,
            certifier: msg.sender,
            ipfsHash: ipfsHash,
            reason: reason
        });
        
        emit KYCStatusUpdated(user, KYCStatus.Verified, msg.sender, reason);
    }
    
    /**
     * @dev Revoke a user's KYC (certifiers and regulators)
     * @param user Address to revoke
     * @param reason Reason for revocation
     */
    function revokeKYC(
        address user,
        string memory reason
    ) external {
        require(
            hasRole(CERTIFIER_ROLE, msg.sender) || hasRole(REGULATOR_ROLE, msg.sender),
            "Not authorized to revoke KYC"
        );
        require(registeredUsers[user], "User not registered");
        require(kycRecords[user].status == KYCStatus.Verified, "User not verified");
        
        kycRecords[user].status = KYCStatus.Revoked;
        kycRecords[user].reason = reason;
        
        emit KYCStatusUpdated(user, KYCStatus.Revoked, msg.sender, reason);
    }
    
    /**
     * @dev Check if a user's KYC is currently valid
     * @param user Address to check
     * @return isValid True if KYC is verified and not expired
     */
    function isKYCValid(address user) external view returns (bool isValid) {
        if (!registeredUsers[user]) return false;
        
        KYCData storage kyc = kycRecords[user];
        
        if (kyc.status != KYCStatus.Verified) return false;
        
        // Check expiration (0 means no expiry)
        if (kyc.expiresAt > 0 && block.timestamp > kyc.expiresAt) {
            return false;
        }
        
        return true;
    }
    
    /**
     * @dev Get KYC status for a user
     * @param user Address to check
     * @return status Current KYC status
     * @return verifiedAt Timestamp when verified (0 if never verified)
     * @return expiresAt Expiration timestamp (0 if no expiry)
     * @return certifier Who verified the KYC
     * @return reason Last status change reason
     */
    function getKYCStatus(address user) 
        external 
        view 
        returns (
            KYCStatus status,
            uint256 verifiedAt,
            uint256 expiresAt,
            address certifier,
            string memory reason
        ) 
    {
        require(registeredUsers[user], "User not registered");
        
        KYCData storage kyc = kycRecords[user];
        return (
            kyc.status,
            kyc.verifiedAt,
            kyc.expiresAt,
            kyc.certifier,
            kyc.reason
        );
    }
    
    /**
     * @dev Get KYC documents hash (only for authorized roles)
     * @param user Address to check
     * @return ipfsHash IPFS hash of KYC documents
     */
    function getKYCDocuments(address user) 
        external 
        view 
        returns (string memory ipfsHash) 
    {
        require(
            hasRole(CERTIFIER_ROLE, msg.sender) || 
            hasRole(REGULATOR_ROLE, msg.sender) || 
            user == msg.sender,
            "Not authorized to view documents"
        );
        require(registeredUsers[user], "User not registered");
        
        return kycRecords[user].ipfsHash;
    }
    
    /**
     * @dev Update KYC documents hash (only certifiers)
     * @param user Address to update
     * @param newIpfsHash New IPFS hash
     */
    function updateKYCDocuments(
        address user,
        string memory newIpfsHash
    ) external onlyRole(CERTIFIER_ROLE) {
        require(registeredUsers[user], "User not registered");
        require(kycRecords[user].status == KYCStatus.Verified, "User not verified");
        
        kycRecords[user].ipfsHash = newIpfsHash;
    }
    
    /**
     * @dev Batch verify multiple users (only certifiers)
     * @param users Array of user addresses
     * @param expiryDuration Expiry duration for all users
     * @param reason Reason for batch verification
     */
    function batchVerifyKYC(
        address[] memory users,
        uint256 expiryDuration,
        string memory reason
    ) external onlyRole(CERTIFIER_ROLE) {
        require(users.length > 0, "Empty user array");
        require(users.length <= 50, "Too many users in batch");
        
        uint256 expiresAt = expiryDuration > 0 ? block.timestamp + expiryDuration : 0;
        
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            require(registeredUsers[user], "User not registered");
            require(kycRecords[user].status != KYCStatus.Verified, "User already verified");
            
            kycRecords[user] = KYCData({
                status: KYCStatus.Verified,
                verifiedAt: block.timestamp,
                expiresAt: expiresAt,
                certifier: msg.sender,
                ipfsHash: "",
                reason: reason
            });
            
            emit KYCStatusUpdated(user, KYCStatus.Verified, msg.sender, reason);
        }
    }
    
    /**
     * @dev Get list of users with specific KYC status
     * @param status KYC status to filter by
     * @return users Array of user addresses with the specified status
     */
    function getUsersByStatus(KYCStatus status) 
        external 
        view 
        onlyRole(REGULATOR_ROLE)
        returns (address[] memory users) 
    {
        uint256 count = 0;
        
        // Count users with specified status
        for (uint256 i = 0; i < userList.length; i++) {
            if (kycRecords[userList[i]].status == status) {
                count++;
            }
        }
        
        // Create result array
        users = new address[](count);
        uint256 index = 0;
        
        for (uint256 i = 0; i < userList.length; i++) {
            if (kycRecords[userList[i]].status == status) {
                users[index] = userList[i];
                index++;
            }
        }
    }
    
    /**
     * @dev Check if KYC will expire soon (within specified time)
     * @param user Address to check
     * @param timeThreshold Time threshold in seconds
     * @return willExpire True if KYC expires within threshold
     */
    function willKYCExpireSoon(address user, uint256 timeThreshold) 
        external 
        view 
        returns (bool willExpire) 
    {
        if (!registeredUsers[user]) return false;
        
        KYCData storage kyc = kycRecords[user];
        if (kyc.status != KYCStatus.Verified || kyc.expiresAt == 0) return false;
        
        return (kyc.expiresAt <= block.timestamp + timeThreshold);
    }
    
    /**
     * @dev Get total count of users by status
     * @return unverified Number of unverified users
     * @return verified Number of verified users  
     * @return revoked Number of revoked users
     */
    function getStatusCounts() 
        external 
        view 
        onlyRole(REGULATOR_ROLE)
        returns (uint256 unverified, uint256 verified, uint256 revoked) 
    {
        for (uint256 i = 0; i < userList.length; i++) {
            KYCStatus status = kycRecords[userList[i]].status;
            if (status == KYCStatus.Unverified) unverified++;
            else if (status == KYCStatus.Verified) verified++;
            else if (status == KYCStatus.Revoked) revoked++;
        }
    }
}
