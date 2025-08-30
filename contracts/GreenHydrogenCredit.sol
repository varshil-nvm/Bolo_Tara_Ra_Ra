// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IKYCRegistry {
    function isKYCValid(address user) external view returns (bool);
}

/**
 * @title GreenHydrogenCredit
 * @dev NFT-based green hydrogen credits with production tracking and lifecycle management
 * Each token represents verified green hydrogen production that can be traded and retired
 */
contract GreenHydrogenCredit is 
    ERC721,
    ERC721Enumerable, 
    ERC721Burnable,
    AccessControl,
    Pausable,
    ReentrancyGuard 
{
    // Role definitions
    bytes32 public constant CERTIFIER_ROLE = keccak256("CERTIFIER_ROLE");
    bytes32 public constant PRODUCER_ROLE = keccak256("PRODUCER_ROLE");
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");
    
    // Credit status enumeration
    enum CreditStatus {
        Active,     // Credit is active and tradeable
        Flagged,    // Credit is under investigation
        Retired     // Credit has been permanently retired (burned)
    }
    
    // Production data structure
    struct ProductionData {
        bytes32 productionHash;      // Unique hash of production data
        address producer;            // Who produced the hydrogen
        uint256 hydrogenAmount;      // Amount of hydrogen in kg (scaled by 1e18)
        uint256 productionDate;      // When the hydrogen was produced
        string facilityId;           // Production facility identifier
        string certificationData;   // IPFS hash of certification documents
        string location;             // Geographic location of production
        uint256 carbonIntensity;     // Carbon intensity (kg CO2/kg H2, scaled by 1e18)
    }
    
    // Credit metadata structure
    struct CreditInfo {
        ProductionData production;
        CreditStatus status;
        uint256 mintedAt;
        uint256 retiredAt;          // 0 if not retired
        address retiredBy;          // Who retired the credit
        string retirementReason;    // Reason for retirement
        address flaggedBy;          // Who flagged the credit (if flagged)
        string flagReason;          // Reason for flagging
    }
    
    // State variables
    mapping(uint256 => CreditInfo) public credits;
    mapping(bytes32 => uint256) public productionHashToTokenId;
    mapping(bytes32 => bool) public usedProductionHashes;
    mapping(address => uint256[]) public producerCredits;
    
    IKYCRegistry public kycRegistry;
    uint256 private _nextTokenId;
    uint256 public totalCreditsIssued;
    uint256 public totalCreditsRetired;
    uint256 public totalHydrogenRepresented; // Total kg of hydrogen across all credits
    
    // Constants
    uint256 public constant MIN_HYDROGEN_AMOUNT = 1e15; // 0.001 kg minimum
    uint256 public constant MAX_CARBON_INTENSITY = 2e18; // 2 kg CO2/kg H2 maximum
    
    // Events
    event CreditMinted(
        uint256 indexed tokenId,
        address indexed producer,
        bytes32 indexed productionHash,
        uint256 hydrogenAmount,
        string facilityId
    );
    
    event CreditRetired(
        uint256 indexed tokenId,
        address indexed retiredBy,
        string reason,
        uint256 timestamp
    );
    
    event CreditFlagged(
        uint256 indexed tokenId,
        address indexed flaggedBy,
        string reason,
        uint256 timestamp
    );
    
    event CreditUnflagged(
        uint256 indexed tokenId,
        address indexed unflaggedBy,
        uint256 timestamp
    );
    
    event KYCRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    
    /**
     * @dev Constructor
     * @param _kycRegistry Address of the KYC registry contract
     */
    constructor(address _kycRegistry) ERC721("Green Hydrogen Credit", "GHC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(CERTIFIER_ROLE, msg.sender);
        _grantRole(REGULATOR_ROLE, msg.sender);
        
        kycRegistry = IKYCRegistry(_kycRegistry);
        _nextTokenId = 1;
    }
    
    /**
     * @dev Mint a new green hydrogen credit
     * @param producer Address of the hydrogen producer
     * @param productionHash Unique hash of production data (prevents double-minting)
     * @param hydrogenAmount Amount of hydrogen produced (kg, scaled by 1e18)
     * @param productionDate When the hydrogen was produced
     * @param facilityId Production facility identifier
     * @param certificationData IPFS hash of certification documents
     * @param location Geographic location of production
     * @param carbonIntensity Carbon intensity (kg CO2/kg H2, scaled by 1e18)
     */
    function mintCredit(
        address producer,
        bytes32 productionHash,
        uint256 hydrogenAmount,
        uint256 productionDate,
        string memory facilityId,
        string memory certificationData,
        string memory location,
        uint256 carbonIntensity
    ) external onlyRole(CERTIFIER_ROLE) nonReentrant whenNotPaused {
        require(producer != address(0), "Invalid producer address");
        require(kycRegistry.isKYCValid(producer), "Producer KYC not valid");
        require(!usedProductionHashes[productionHash], "Production hash already used");
        require(hydrogenAmount >= MIN_HYDROGEN_AMOUNT, "Hydrogen amount too small");
        require(carbonIntensity <= MAX_CARBON_INTENSITY, "Carbon intensity too high");
        require(productionDate <= block.timestamp, "Production date cannot be in future");
        require(bytes(facilityId).length > 0, "Facility ID required");
        require(bytes(certificationData).length > 0, "Certification data required");
        
        uint256 tokenId = _nextTokenId++;
        
        // Mark production hash as used
        usedProductionHashes[productionHash] = true;
        productionHashToTokenId[productionHash] = tokenId;
        
        // Create production data
        ProductionData memory production = ProductionData({
            productionHash: productionHash,
            producer: producer,
            hydrogenAmount: hydrogenAmount,
            productionDate: productionDate,
            facilityId: facilityId,
            certificationData: certificationData,
            location: location,
            carbonIntensity: carbonIntensity
        });
        
        // Create credit info
        credits[tokenId] = CreditInfo({
            production: production,
            status: CreditStatus.Active,
            mintedAt: block.timestamp,
            retiredAt: 0,
            retiredBy: address(0),
            retirementReason: "",
            flaggedBy: address(0),
            flagReason: ""
        });
        
        // Track producer credits
        producerCredits[producer].push(tokenId);
        
        // Update totals
        totalCreditsIssued++;
        totalHydrogenRepresented += hydrogenAmount;
        
        // Mint NFT
        _safeMint(producer, tokenId);
        
        emit CreditMinted(tokenId, producer, productionHash, hydrogenAmount, facilityId);
    }
    
    /**
     * @dev Batch mint multiple credits (gas efficient for large batches)
     * @param mintData Array of mint parameters
     */
    function batchMintCredits(
        MintData[] memory mintData
    ) external onlyRole(CERTIFIER_ROLE) nonReentrant whenNotPaused {
        require(mintData.length > 0, "Empty mint data");
        require(mintData.length <= 100, "Batch too large");
        
        for (uint256 i = 0; i < mintData.length; i++) {
            MintData memory data = mintData[i];
            
            require(data.producer != address(0), "Invalid producer address");
            require(kycRegistry.isKYCValid(data.producer), "Producer KYC not valid");
            require(!usedProductionHashes[data.productionHash], "Production hash already used");
            require(data.hydrogenAmount >= MIN_HYDROGEN_AMOUNT, "Hydrogen amount too small");
            require(data.carbonIntensity <= MAX_CARBON_INTENSITY, "Carbon intensity too high");
            require(data.productionDate <= block.timestamp, "Production date cannot be in future");
            
            uint256 tokenId = _nextTokenId++;
            
            // Mark production hash as used
            usedProductionHashes[data.productionHash] = true;
            productionHashToTokenId[data.productionHash] = tokenId;
            
            // Create production data
            ProductionData memory production = ProductionData({
                productionHash: data.productionHash,
                producer: data.producer,
                hydrogenAmount: data.hydrogenAmount,
                productionDate: data.productionDate,
                facilityId: data.facilityId,
                certificationData: data.certificationData,
                location: data.location,
                carbonIntensity: data.carbonIntensity
            });
            
            // Create credit info
            credits[tokenId] = CreditInfo({
                production: production,
                status: CreditStatus.Active,
                mintedAt: block.timestamp,
                retiredAt: 0,
                retiredBy: address(0),
                retirementReason: "",
                flaggedBy: address(0),
                flagReason: ""
            });
            
            // Track producer credits
            producerCredits[data.producer].push(tokenId);
            
            // Update totals
            totalCreditsIssued++;
            totalHydrogenRepresented += data.hydrogenAmount;
            
            // Mint NFT
            _safeMint(data.producer, tokenId);
            
            emit CreditMinted(tokenId, data.producer, data.productionHash, data.hydrogenAmount, data.facilityId);
        }
    }
    
    /**
     * @dev Retire (burn) a credit permanently
     * @param tokenId The credit to retire
     * @param reason Reason for retirement
     */
    function retireCredit(
        uint256 tokenId,
        string memory reason
    ) external nonReentrant {
        require(_ownerOf(tokenId) == msg.sender, "Not the owner of this credit");
        require(credits[tokenId].status == CreditStatus.Active, "Credit not active");
        require(bytes(reason).length > 0, "Retirement reason required");
        
        // Update credit status
        credits[tokenId].status = CreditStatus.Retired;
        credits[tokenId].retiredAt = block.timestamp;
        credits[tokenId].retiredBy = msg.sender;
        credits[tokenId].retirementReason = reason;
        
        // Update totals
        totalCreditsRetired++;
        
        // Burn the NFT
        _burn(tokenId);
        
        emit CreditRetired(tokenId, msg.sender, reason, block.timestamp);
    }
    
    /**
     * @dev Flag a credit for investigation (regulators only)
     * @param tokenId The credit to flag
     * @param reason Reason for flagging
     */
    function flagCredit(
        uint256 tokenId,
        string memory reason
    ) external onlyRole(REGULATOR_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Credit does not exist");
        require(credits[tokenId].status == CreditStatus.Active, "Credit not active");
        require(bytes(reason).length > 0, "Flag reason required");
        
        credits[tokenId].status = CreditStatus.Flagged;
        credits[tokenId].flaggedBy = msg.sender;
        credits[tokenId].flagReason = reason;
        
        emit CreditFlagged(tokenId, msg.sender, reason, block.timestamp);
    }
    
    /**
     * @dev Unflag a credit (regulators only)
     * @param tokenId The credit to unflag
     */
    function unflagCredit(uint256 tokenId) external onlyRole(REGULATOR_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Credit does not exist");
        require(credits[tokenId].status == CreditStatus.Flagged, "Credit not flagged");
        
        credits[tokenId].status = CreditStatus.Active;
        credits[tokenId].flaggedBy = address(0);
        credits[tokenId].flagReason = "";
        
        emit CreditUnflagged(tokenId, msg.sender, block.timestamp);
    }
    
    /**
     * @dev Get credit information
     * @param tokenId The credit token ID
     */
    function getCreditInfo(uint256 tokenId) 
        external 
        view 
        returns (CreditInfo memory creditInfo) 
    {
        require(tokenId > 0 && tokenId < _nextTokenId, "Invalid token ID");
        return credits[tokenId];
    }
    
    /**
     * @dev Get production data for a credit
     * @param tokenId The credit token ID
     */
    function getProductionData(uint256 tokenId) 
        external 
        view 
        returns (ProductionData memory production) 
    {
        require(_ownerOf(tokenId) != address(0), "Credit does not exist");
        return credits[tokenId].production;
    }
    
    /**
     * @dev Check if a production hash has been used
     * @param productionHash The production hash to check
     * @return used True if the hash has been used
     * @return tokenId The token ID associated with the hash (0 if not used)
     */
    function isProductionHashUsed(bytes32 productionHash) 
        external 
        view 
        returns (bool used, uint256 tokenId) 
    {
        used = usedProductionHashes[productionHash];
        tokenId = used ? productionHashToTokenId[productionHash] : 0;
    }
    
    /**
     * @dev Get all credits owned by a producer
     * @param producer The producer address
     * @return tokenIds Array of token IDs owned by the producer
     */
    function getProducerCredits(address producer) 
        external 
        view 
        returns (uint256[] memory tokenIds) 
    {
        return producerCredits[producer];
    }
    
    /**
     * @dev Get credits by status
     * @param status The status to filter by
     * @return tokenIds Array of token IDs with the specified status
     */
    function getCreditsByStatus(CreditStatus status) 
        external 
        view 
        onlyRole(REGULATOR_ROLE)
        returns (uint256[] memory tokenIds) 
    {
        uint256 count = 0;
        
        // Count credits with specified status
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (credits[i].status == status) {
                count++;
            }
        }
        
        // Create result array
        tokenIds = new uint256[](count);
        uint256 index = 0;
        
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (credits[i].status == status) {
                tokenIds[index] = i;
                index++;
            }
        }
    }
    
    /**
     * @dev Get aggregate statistics
     * @return totalIssued Total credits issued
     * @return totalRetired Total credits retired
     * @return totalActive Total active credits
     * @return totalFlagged Total flagged credits
     * @return totalHydrogen Total hydrogen represented (kg, scaled by 1e18)
     */
    function getAggregateStats() 
        external 
        view 
        returns (
            uint256 totalIssued,
            uint256 totalRetired,
            uint256 totalActive,
            uint256 totalFlagged,
            uint256 totalHydrogen
        ) 
    {
        totalIssued = totalCreditsIssued;
        totalRetired = totalCreditsRetired;
        totalHydrogen = totalHydrogenRepresented;
        
        // Count active and flagged credits
        for (uint256 i = 1; i < _nextTokenId; i++) {
            if (credits[i].status == CreditStatus.Active) {
                totalActive++;
            } else if (credits[i].status == CreditStatus.Flagged) {
                totalFlagged++;
            }
        }
    }
    
    /**
     * @dev Override transfer functions to check KYC and status
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721, IERC721) {
        require(kycRegistry.isKYCValid(to), "Recipient KYC not valid");
        require(credits[tokenId].status == CreditStatus.Active, "Credit not transferable");
        super.transferFrom(from, to, tokenId);
    }
    
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) public override(ERC721, IERC721) {
        require(kycRegistry.isKYCValid(to), "Recipient KYC not valid");
        require(credits[tokenId].status == CreditStatus.Active, "Credit not transferable");
        super.safeTransferFrom(from, to, tokenId, data);
    }
    
    /**
     * @dev Update KYC registry address (only admin)
     * @param newKYCRegistry New KYC registry address
     */
    function updateKYCRegistry(address newKYCRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newKYCRegistry != address(0), "Invalid KYC registry address");
        
        address oldRegistry = address(kycRegistry);
        kycRegistry = IKYCRegistry(newKYCRegistry);
        
        emit KYCRegistryUpdated(oldRegistry, newKYCRegistry);
    }
    
    /**
     * @dev Pause the contract (emergency use only)
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }
    
    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
    
    /**
     * @dev Get token URI for metadata
     * @param tokenId The token ID
     * @return URI pointing to token metadata
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Credit does not exist");
        
        // Return base URI + tokenId + ".json"
        // In production, this would point to a metadata service
        return string(abi.encodePacked(
            "https://api.greenhydrogencredits.com/metadata/",
            Strings.toString(tokenId),
            ".json"
        ));
    }
    
    /**
     * @dev Emergency burn function (regulators only)
     * @param tokenId The credit to burn
     * @param reason Reason for emergency burn
     */
    function emergencyBurn(
        uint256 tokenId,
        string memory reason
    ) external onlyRole(REGULATOR_ROLE) {
        require(_ownerOf(tokenId) != address(0), "Credit does not exist");
        require(bytes(reason).length > 0, "Burn reason required");
        
        // Update credit status
        credits[tokenId].status = CreditStatus.Retired;
        credits[tokenId].retiredAt = block.timestamp;
        credits[tokenId].retiredBy = msg.sender;
        credits[tokenId].retirementReason = reason;
        
        // Update totals
        totalCreditsRetired++;
        
        // Burn the NFT
        _burn(tokenId);
        
        emit CreditRetired(tokenId, msg.sender, reason, block.timestamp);
    }
    
    // Required overrides for multiple inheritance
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value)
        internal
        override(ERC721, ERC721Enumerable)
    {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/**
 * @dev Struct for batch minting data
 */
struct MintData {
    address producer;
    bytes32 productionHash;
    uint256 hydrogenAmount;
    uint256 productionDate;
    string facilityId;
    string certificationData;
    string location;
    uint256 carbonIntensity;
}
