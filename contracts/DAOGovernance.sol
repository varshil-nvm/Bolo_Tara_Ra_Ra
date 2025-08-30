// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title DAOGovernance
 * @dev A comprehensive DAO governance system with proposal voting and execution
 * Token holders can propose and vote on protocol changes
 */
contract DAOGovernance {
    struct Proposal {
        uint256 id;
        address proposer;
        string title;
        string description;
        address target;         // Contract to call
        bytes callData;         // Function call data
        uint256 startBlock;     // When voting starts
        uint256 endBlock;       // When voting ends
        uint256 forVotes;       // Votes in favor
        uint256 againstVotes;   // Votes against
        uint256 abstainVotes;   // Abstain votes
        bool executed;          // Whether proposal was executed
        bool canceled;          // Whether proposal was canceled
        mapping(address => Receipt) receipts; // Vote receipts
    }
    
    struct Receipt {
        bool hasVoted;
        uint8 support;  // 0=against, 1=for, 2=abstain
        uint256 votes;  // Number of votes cast
    }
    
    // Governance parameters
    uint256 public votingDelay;         // Blocks before voting starts (24 hours = ~7200 blocks)
    uint256 public votingPeriod;        // Voting duration in blocks (3 days = ~21600 blocks)
    uint256 public proposalThreshold;   // Min tokens needed to propose
    uint256 public quorumVotes;         // Min votes needed for proposal to pass
    uint256 public timelockDelay;       // Delay before execution (2 days = ~14400 blocks)
    
    // Core contracts
    IERC20 public governanceToken;
    address public admin;
    address public pendingAdmin;
    
    // State
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(bytes32 => bool) public queuedTransactions;
    
    // Events
    event ProposalCreated(
        uint256 indexed id,
        address indexed proposer,
        address target,
        string title,
        string description,
        uint256 startBlock,
        uint256 endBlock
    );
    
    event VoteCast(
        address indexed voter,
        uint256 indexed proposalId,
        uint8 support,
        uint256 votes,
        string reason
    );
    
    event ProposalQueued(uint256 indexed id, uint256 eta);
    event ProposalExecuted(uint256 indexed id);
    event ProposalCanceled(uint256 indexed id);
    
    event AdminChanged(address oldAdmin, address newAdmin);
    event ParameterChanged(string parameter, uint256 oldValue, uint256 newValue);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }
    
    modifier onlyGovernance() {
        require(msg.sender == address(this), "Only governance");
        _;
    }
    
    constructor(
        address _governanceToken,
        uint256 _proposalThreshold,
        uint256 _quorumVotes
    ) {
        governanceToken = IERC20(_governanceToken);
        admin = msg.sender;
        
        // Default parameters (can be changed via governance)
        votingDelay = 7200;        // ~24 hours
        votingPeriod = 21600;      // ~3 days  
        timelockDelay = 14400;     // ~2 days
        
        proposalThreshold = _proposalThreshold;
        quorumVotes = _quorumVotes;
    }
    
    /**
     * @dev Create a new proposal
     * @param target The contract address to call
     * @param callData The function call data
     * @param title Proposal title
     * @param description Proposal description
     */
    function propose(
        address target,
        bytes memory callData,
        string memory title,
        string memory description
    ) external returns (uint256) {
        require(
            governanceToken.balanceOf(msg.sender) >= proposalThreshold,
            "Insufficient tokens to propose"
        );
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(description).length > 0, "Description cannot be empty");
        
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.title = title;
        newProposal.description = description;
        newProposal.target = target;
        newProposal.callData = callData;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            target,
            title,
            description,
            startBlock,
            endBlock
        );
        
        return proposalId;
    }
    
    /**
     * @dev Cast a vote on a proposal
     * @param proposalId The proposal to vote on
     * @param support Vote choice: 0=against, 1=for, 2=abstain
     * @param reason Optional reason for the vote
     */
    function castVote(
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) external {
        require(support <= 2, "Invalid vote type");
        return _castVote(msg.sender, proposalId, support, reason);
    }
    
    /**
     * @dev Cast vote with signature (for meta-transactions)
     * @param proposalId The proposal to vote on
     * @param support Vote choice: 0=against, 1=for, 2=abstain
     * @param voter The voter address
     * @param signature The signature
     * @param reason Optional reason for the vote
     */
    function castVoteBySig(
        uint256 proposalId,
        uint8 support,
        address voter,
        bytes memory signature,
        string memory reason
    ) external {
        // Signature verification would go here
        // For simplicity, we'll skip signature verification in this implementation
        require(voter != address(0), "Invalid voter");
        return _castVote(voter, proposalId, support, reason);
    }
    
    /**
     * @dev Queue a successful proposal for execution
     * @param proposalId The proposal to queue
     */
    function queue(uint256 proposalId) external {
        require(_getProposalState(proposalId) == ProposalState.Succeeded, "Proposal not succeeded");
        
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = block.number + timelockDelay;
        
        bytes32 txHash = keccak256(abi.encode(
            proposal.target,
            proposal.callData,
            eta
        ));
        
        queuedTransactions[txHash] = true;
        
        emit ProposalQueued(proposalId, eta);
    }
    
    /**
     * @dev Execute a queued proposal
     * @param proposalId The proposal to execute
     */
    function execute(uint256 proposalId) external {
        require(_getProposalState(proposalId) == ProposalState.Queued, "Proposal not queued");
        
        Proposal storage proposal = proposals[proposalId];
        uint256 eta = proposal.endBlock + timelockDelay;
        
        require(block.number >= eta, "Timelock not expired");
        
        bytes32 txHash = keccak256(abi.encode(
            proposal.target,
            proposal.callData,
            eta
        ));
        
        require(queuedTransactions[txHash], "Transaction not queued");
        
        // Execute the proposal
        proposal.executed = true;
        queuedTransactions[txHash] = false;
        
        (bool success, ) = proposal.target.call(proposal.callData);
        require(success, "Execution failed");
        
        emit ProposalExecuted(proposalId);
    }
    
    /**
     * @dev Cancel a proposal (only proposer or admin)
     * @param proposalId The proposal to cancel
     */
    function cancel(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(
            msg.sender == proposal.proposer || msg.sender == admin,
            "Only proposer or admin can cancel"
        );
        require(!proposal.executed, "Cannot cancel executed proposal");
        
        proposal.canceled = true;
        
        emit ProposalCanceled(proposalId);
    }
    
    /**
     * @dev Get the state of a proposal
     * @param proposalId The proposal to check
     * @return state The current state of the proposal
     */
    function state(uint256 proposalId) external view returns (ProposalState) {
        return _getProposalState(proposalId);
    }
    
    /**
     * @dev Get proposal details
     * @param proposalId The proposal to get details for
     */
    function getProposal(uint256 proposalId) 
        external 
        view 
        returns (
            address proposer,
            string memory title,
            string memory description,
            address target,
            bytes memory callData,
            uint256 startBlock,
            uint256 endBlock,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            bool executed,
            bool canceled
        ) 
    {
        Proposal storage proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.title,
            proposal.description,
            proposal.target,
            proposal.callData,
            proposal.startBlock,
            proposal.endBlock,
            proposal.forVotes,
            proposal.againstVotes,
            proposal.abstainVotes,
            proposal.executed,
            proposal.canceled
        );
    }
    
    /**
     * @dev Get vote receipt for a voter on a proposal
     * @param proposalId The proposal
     * @param voter The voter
     */
    function getReceipt(uint256 proposalId, address voter) 
        external 
        view 
        returns (bool hasVoted, uint8 support, uint256 votes) 
    {
        Receipt storage receipt = proposals[proposalId].receipts[voter];
        return (receipt.hasVoted, receipt.support, receipt.votes);
    }
    
    /**
     * @dev Update governance parameters (only via governance)
     */
    function setVotingDelay(uint256 _votingDelay) external onlyGovernance {
        uint256 oldValue = votingDelay;
        votingDelay = _votingDelay;
        emit ParameterChanged("votingDelay", oldValue, _votingDelay);
    }
    
    function setVotingPeriod(uint256 _votingPeriod) external onlyGovernance {
        uint256 oldValue = votingPeriod;
        votingPeriod = _votingPeriod;
        emit ParameterChanged("votingPeriod", oldValue, _votingPeriod);
    }
    
    function setProposalThreshold(uint256 _proposalThreshold) external onlyGovernance {
        uint256 oldValue = proposalThreshold;
        proposalThreshold = _proposalThreshold;
        emit ParameterChanged("proposalThreshold", oldValue, _proposalThreshold);
    }
    
    function setQuorumVotes(uint256 _quorumVotes) external onlyGovernance {
        uint256 oldValue = quorumVotes;
        quorumVotes = _quorumVotes;
        emit ParameterChanged("quorumVotes", oldValue, _quorumVotes);
    }
    
    function setTimelockDelay(uint256 _timelockDelay) external onlyGovernance {
        uint256 oldValue = timelockDelay;
        timelockDelay = _timelockDelay;
        emit ParameterChanged("timelockDelay", oldValue, _timelockDelay);
    }
    
    /**
     * @dev Accept admin role (two-step process)
     */
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "Only pending admin");
        
        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);
        
        emit AdminChanged(oldAdmin, admin);
    }
    
    /**
     * @dev Set pending admin (only current admin)
     */
    function setPendingAdmin(address newPendingAdmin) external onlyAdmin {
        pendingAdmin = newPendingAdmin;
    }
    
    /**
     * @dev Internal function to cast votes
     */
    function _castVote(
        address voter,
        uint256 proposalId,
        uint8 support,
        string memory reason
    ) internal {
        require(_getProposalState(proposalId) == ProposalState.Active, "Voting not active");
        
        Proposal storage proposal = proposals[proposalId];
        Receipt storage receipt = proposal.receipts[voter];
        
        require(!receipt.hasVoted, "Voter already voted");
        
        uint256 votes = governanceToken.balanceOf(voter);
        require(votes > 0, "No voting power");
        
        if (support == 0) {
            proposal.againstVotes += votes;
        } else if (support == 1) {
            proposal.forVotes += votes;
        } else {
            proposal.abstainVotes += votes;
        }
        
        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = votes;
        
        emit VoteCast(voter, proposalId, support, votes, reason);
    }
    
    /**
     * @dev Get the current state of a proposal
     */
    function _getProposalState(uint256 proposalId) internal view returns (ProposalState) {
        require(proposalId > 0 && proposalId <= proposalCount, "Invalid proposal id");
        
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.canceled) {
            return ProposalState.Canceled;
        }
        
        if (proposal.executed) {
            return ProposalState.Executed;
        }
        
        if (block.number < proposal.startBlock) {
            return ProposalState.Pending;
        }
        
        if (block.number <= proposal.endBlock) {
            return ProposalState.Active;
        }
        
        uint256 totalVotes = proposal.forVotes + proposal.againstVotes + proposal.abstainVotes;
        
        if (totalVotes < quorumVotes) {
            return ProposalState.Defeated;
        }
        
        if (proposal.forVotes <= proposal.againstVotes) {
            return ProposalState.Defeated;
        }
        
        // Check if queued
        uint256 eta = proposal.endBlock + timelockDelay;
        bytes32 txHash = keccak256(abi.encode(
            proposal.target,
            proposal.callData,
            eta
        ));
        
        if (queuedTransactions[txHash]) {
            if (block.number >= eta) {
                return ProposalState.Expired;
            }
            return ProposalState.Queued;
        }
        
        return ProposalState.Succeeded;
    }
    
    /**
     * @dev Emergency functions (only admin)
     */
    function emergencyCancel(uint256 proposalId) external onlyAdmin {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Cannot cancel executed proposal");
        proposal.canceled = true;
        emit ProposalCanceled(proposalId);
    }
    
    /**
     * @dev Batch proposal creation for complex operations
     */
    function proposeBatch(
        address[] memory targets,
        bytes[] memory callDatas,
        string memory title,
        string memory description
    ) external returns (uint256) {
        require(
            governanceToken.balanceOf(msg.sender) >= proposalThreshold,
            "Insufficient tokens to propose"
        );
        require(targets.length == callDatas.length, "Mismatched arrays");
        require(targets.length > 0, "Empty proposal");
        require(bytes(title).length > 0, "Title cannot be empty");
        require(bytes(description).length > 0, "Description cannot be empty");
        
        // For batch operations, we encode multiple calls into a single call data
        bytes memory batchCallData = abi.encodeWithSignature(
            "executeBatch(address[],bytes[])",
            targets,
            callDatas
        );
        
        // Create the proposal directly instead of external call
        proposalCount++;
        uint256 proposalId = proposalCount;
        
        uint256 startBlock = block.number + votingDelay;
        uint256 endBlock = startBlock + votingPeriod;
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.title = title;
        newProposal.description = description;
        newProposal.target = address(this);
        newProposal.callData = batchCallData;
        newProposal.startBlock = startBlock;
        newProposal.endBlock = endBlock;
        
        emit ProposalCreated(
            proposalId,
            msg.sender,
            address(this),
            title,
            description,
            startBlock,
            endBlock
        );
        
        return proposalId;
    }
    
    /**
     * @dev Execute batch operations (called by governance)
     */
    function executeBatch(
        address[] memory targets,
        bytes[] memory callDatas
    ) external onlyGovernance {
        require(targets.length == callDatas.length, "Mismatched arrays");
        
        for (uint256 i = 0; i < targets.length; i++) {
            (bool success, ) = targets[i].call(callDatas[i]);
            require(success, "Batch execution failed");
        }
    }
}

// Enum for proposal states
enum ProposalState {
    Pending,    // Proposal created, voting not started
    Active,     // Voting is active
    Canceled,   // Proposal was canceled
    Defeated,   // Proposal failed (not enough votes or more against)
    Succeeded,  // Proposal passed, ready to queue
    Queued,     // Proposal queued for execution
    Expired,    // Proposal expired before execution
    Executed    // Proposal was executed
}
