//SPDX-License-Identifier:MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract DecentralizedGovernance is ReentrancyGuard{
    using SafeCast for uint256;
    struct Proposal{
        uint256 id;
        string description;
        uint256 deadline;
        uint256 votesFor;
        uint256 votesAgainst;
        bool executed;
        address proposer;
        bytes[] executionData;
        address[] executionTargets;
        uint256 executionTime;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    address public admin;
    IERC20 public governanceToken;
    uint256 public nextproposalId;
    uint256 public votingDuration;
    uint256 public timelockDuration;
    uint256 public quorumPercentage = 5;
    uint256 public proposalDepositAmount = 10;

    event ProposalCreated(uint256 id, string description, address proposer, uint256 depositAmount);
    event Voted(uint256 proposalId, address voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 id, bool passed);
    event ProposalDepositPaid(address proposer, uint256 amount);
    event ProposalDepositRefunded(address proposer, uint256 amount);
    event QuorumNotMet(uint256 id, uint256 votesTotal, uint256 quorumNeeded);
    event TimelockSet(uint256 duration);
    event ProposalTimelockStarted(uint256 id, uint256 executionTime);

    modifier onlyAdmin(){
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    constructor(address _governanceToken, uint256 _votingDuration, uint256 _timelockDuration){
        governanceToken = IERC20(_governanceToken);
        votingDuration = _votingDuration;
        timelockDuration = _timelockDuration;
        admin = msg.sender;
        emit TimelockSet(_timelockDuration);
    }

    function setQuorumPercentage(uint256 _quorumPercentage) external onlyAdmin{
        require(_quorumPercentage <= 100, "Quorum percentage must be between 0 and 100");
        quorumPercentage = _quorumPercentage;
    }

    function setProposalDepositAmount(uint256 _proposalDepositAmount) external onlyAdmin{
        proposalDepositAmount = _proposalDepositAmount;
    }

    function setTimelockDuration(uint256 _timelockDuration) external onlyAdmin{
        timelockDuration = _timelockDuration;
        emit TimelockSet(_timelockDuration);
    }

    function createProposal(string calldata _description, address[] calldata _targets, bytes[] calldata _calldatas) external returns(uint256){
        require(governanceToken.balanceOf(msg.sender) >= proposalDepositAmount, "Not enough governance tokens to create proposal");
        require(_targets.length == _calldatas.length, "Targets and calldata length is a mismatch");
        governanceToken.transferFrom(msg.sender, address(this), proposalDepositAmount);
        emit ProposalDepositPaid(msg.sender, proposalDepositAmount);

        proposals[nextproposalId] = Proposal({
            id: nextproposalId,
            description: _description,
            deadline: block.timestamp + votingDuration,
            votesFor: 0,
            votesAgainst: 0,
            executed: false,
            proposer: msg.sender,
            executionData: _calldatas,
            executionTargets: _targets,
            executionTime: 0
        });
        emit ProposalCreated(nextproposalId, _description, msg.sender, proposalDepositAmount);
        nextproposalId++;
        return nextproposalId - 1;
    }

    function vote(uint256 proposalId, bool support) external{
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp < proposal.deadline, "Voting period over");
        require(governanceToken.balanceOf(msg.sender) > 0, "No governance tokens to vote on this proposal");
        require(!hasVoted[proposalId][msg.sender], "Already voted for this proposal");
        uint256 weight = governanceToken.balanceOf(msg.sender);
        if(support){proposal.votesFor += weight;}
        else{proposal.votesAgainst += weight;}
        hasVoted[proposalId][msg.sender] = true;
        emit Voted(proposalId, msg.sender, support, weight);
    }

    function finalizeProposal(uint256 proposalId) external{
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp < proposal.deadline, "Voting period over");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.executionTime == 0, "Execution time is already set");
        uint256 totalSupply = governanceToken.totalSupply();
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 quorumNeeded = (totalSupply * quorumPercentage)/100;

        if(totalVotes >= quorumNeeded && proposal.votesFor > proposal.votesAgainst){
            proposal.executionTime = block.timestamp + timelockDuration;
            emit ProposalTimelockStarted(proposalId, proposal.executionTime);
        }
        else{
            proposal.executed = true;
            emit ProposalExecuted(proposalId, false);
            if(totalVotes < quorumNeeded){
                emit QuorumNotMet(proposalId, totalVotes, quorumNeeded);
            }
        }
    }

    function executeProposal(uint256 proposalId) external nonReentrant{
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(proposal.executionTime > 0 && block.timestamp >= proposal.executionTime, "Timelock has not expired");
        proposal.executed = true;
        bool passed = proposal.votesFor > proposal.votesAgainst;
        if(passed){
            for(uint256 i = 0; i < proposal.executionTargets.length; i++){
                (bool success, bytes memory returnData) = proposal.executionTargets[i].call(proposal.executionData[i]);
                require(success, string(returnData));
            }
            emit ProposalExecuted(proposalId, true);
            governanceToken.transfer(proposal.proposer, proposalDepositAmount);
            emit ProposalDepositRefunded(proposal.proposer, proposalDepositAmount);
        }
        else{emit ProposalExecuted(proposalId, false);}
    }

    function getProposalResult(uint256 proposalId) external view returns(string memory){
        Proposal storage proposal = proposals[proposalId];
        require(proposal.executed, "Proposal not yet executed");
        uint256 totalSupply = governanceToken.totalSupply();
        uint256 totalVotes = proposal.votesFor + proposal.votesAgainst;
        uint256 quorumNeeded = (totalSupply * quorumPercentage)/100;
        if(totalVotes < quorumNeeded){
            return "Proposal failed-quorum not met";
        }
        else if(proposal.votesFor > proposal.votesAgainst){
            return "Proposal passed";
        }
        else{
            return "Proposal rejected";
        }
    }

    function getProposalDetails(uint256 proposalId) external view returns(Proposal memory){
        return proposals[proposalId];
    }

}
