// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import "./../interface/IStaking.sol";
import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "../../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "../../lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

contract GovernorResearch is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    ///*** ERRORS ***///
    error BurnThresholdNotReached(uint256 totBurned, uint256 threshold);
    error ContractTerminated(uint256 blockNumber);
    error IncorrectCoinValue();
    error IncorrectPaymentOption();
    error IncorrectPhase(ProposalStatus);
    error InsufficientBalance(uint256 balance, uint256 requiredBalance);
    error InvalidInput();
    error ProposalLifeTimePassed();
    error ProposalLock();
    error ProposalOngoing(uint256 id, uint256 currentBlock, uint256 endBlock);
    error ProposalInexistent();
    error QuorumNotReached();
    error Unauthorized(address user);
    error VoteLock();

    ///*** STRUCTS ***///
    struct Proposal {
        uint256 startBlockNum;
        uint256 endTimeStamp;
        ProposalStatus status;
        ProjectInfo details;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 totalVotes;
    }

    struct ProjectInfo {
        string info; //IPFS link
        address receivingWallet; //wallet address to send funds to
        Payment payment;
        uint256 amount; //amount of usdc or coin
        uint256 amountSci; //amount of sci token
        bool executable;
    }

    ///*** GOVERNANCE PARAMETERS ***///
    uint256 public proposalLifeTime;
    uint256 public quorum;
    uint256 public proposeLockTime;
    uint256 public voteLockTime;
    uint256 public terminationThreshold;

    ///*** KEY ADDRESSES ***///
    address public stakingAddress;
    address public treasuryWallet;
    address public donationWallet;
    address public usdc;
    address public sci;

    ///*** STORAGE & MAPPINGS ***///
    uint256 public ddThreshold;
    uint256 public totBurnedForTermination;
    uint256 private _index;
    bytes32 public constant DUE_DILIGENCE_ROLE =
        keccak256("DUE_DILIGENCE_ROLE");
    bool public terminated = false;
    uint256 constant VOTE = 1;
    mapping(uint256 => Proposal) private proposals;
    mapping(uint256 => mapping(address => uint8)) private voted;
    mapping(address => uint8) private proposedResearch;

    ///*** ENUMERATORS ***///
    enum ProposalStatus {
        Active,
        Scheduled,
        Executed,
        Completed, //Completed status only for proposals that cannot be executed
        Cancelled
    }

    enum Payment {
        Usdc,
        Sci,
        Coin,
        SciUsdc
    }

    ///*** MODIFIER ***///
    modifier notTerminated() {
        if (terminated) revert ContractTerminated(block.number);
        _;
    }

    /*** EVENTS ***/
    event BurnedForTermination(address owner, uint256 amount);
    event Completed(uint256 indexed id);
    event Cancelled(uint256 indexed id);
    event Executed(uint256 indexed id, bool indexed donated, uint256 amount);
    event Proposed(uint256 indexed id, address proposer, ProjectInfo details);
    event Voted(
        uint256 indexed id,
        address indexed voter,
        bool indexed support,
        uint256 amount
    );
    event Scheduled(uint256 indexed id, bool indexed research);
    event Terminated(address admin, uint256 blockNumber);

    constructor(
        address stakingAddress_,
        address treasuryWallet_,
        address donationWallet_,
        address usdc_,
        address sci_
    ) {
        stakingAddress = stakingAddress_;
        treasuryWallet = treasuryWallet_;
        donationWallet = donationWallet_;
        usdc = usdc_;
        sci = sci_;

        ddThreshold = 1000e18;

        proposalLifeTime = 0;
        quorum = 1;
        voteLockTime = 0;
        proposeLockTime = 0;
        terminationThreshold = (IERC20(sci).totalSupply() / 10000) * 500; // 5% of the total supply must be burned

        _grantRole(DEFAULT_ADMIN_ROLE, treasuryWallet_);
        _grantRole(DEFAULT_ADMIN_ROLE, donationWallet_);

        _grantRole(DUE_DILIGENCE_ROLE, treasuryWallet_);
        _setRoleAdmin(DUE_DILIGENCE_ROLE, DEFAULT_ADMIN_ROLE);
    }

    ///*** EXTERNAL FUNCTIONS ***///

    /**
     * @dev sets the threshold for DD members to propose
     */
    function setStakedSciThreshold(
        uint256 thresholdDDMember
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        ddThreshold = thresholdDDMember;
    }

    /**
     * @dev grants Due Diligence role to member
     * @param member the address of the DAO member
     */
    function grantDueDiligenceRole(
        address member
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        IStaking staking = IStaking(stakingAddress);
        _validateStakingRequirements(staking, member);
        _grantRole(DUE_DILIGENCE_ROLE, member);
    }

    /**
     * @dev revokes Due Diligence role to member
     * @param member the address of the DAO member
     */
    function revokeDueDiligenceRole(
        address member
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(DUE_DILIGENCE_ROLE, member);
    }

    /**
     * @dev sets the treasury wallet address
     */
    function setTreasuryWallet(
        address newTreasuryWallet
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        treasuryWallet = newTreasuryWallet;
    }

    /**
     * @dev sets the donation wallet address
     */
    function setDonationWallet(
        address newDonationWallet
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        donationWallet = newDonationWallet;
    }

    /**
     * @dev sets the staking address
     */
    function setStakingAddress(
        address newStakingAddress
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        stakingAddress = newStakingAddress;
    }

    /**
     * @dev sets the governance parameters given data
     * @param param the parameter of interest
     * @param data the data assigned to the parameter
     */
    function setGovParams(
        bytes32 param,
        uint256 data
    ) external notTerminated onlyRole(DEFAULT_ADMIN_ROLE) {
        //the duration of the proposal
        if (param == "proposalLifeTime") proposalLifeTime = data;

        //the amount of tokens needed to pass a proposal
        //provide a percentage of the total supply
        if (param == "quorum") quorum = data;

        //the lock time of your tokens after voting
        if (param == "voteLockTime") voteLockTime = data;

        //the lock time of your tokens and ability to propose after proposing
        if (param == "proposeLockTime") proposeLockTime = data;

        //the amount of tokens that need to be burned to terminate DAO operations governance
        if (param == "terminationThreshold") terminationThreshold = data;
    }

    /**
     * @dev proposes a research project in need of funding
     *      at least one option needs to be proposed
     * @param info ipfs hash of project proposal
     * @param receivingWallet the address of the research group receiving funds if proposal passed
     * @param amountUsdc the amount of USDC
     * @param amountCoin the amount of Coin
     * @param amountSci the amount of SCI tokens
     */
    function propose(
        string memory info,
        address receivingWallet,
        uint256 amountUsdc,
        uint256 amountCoin,
        uint256 amountSci
    )
        external
        nonReentrant
        notTerminated
        onlyRole(DUE_DILIGENCE_ROLE)
        returns (uint256)
    {
        _validateInput(
            info,
            receivingWallet,
            amountUsdc,
            amountCoin,
            amountSci
        );

        IStaking staking = IStaking(stakingAddress);
        _validateStakingRequirements(staking, msg.sender);

        (
            Payment payment,
            uint256 amount,
            uint256 sciAmount
        ) = _determinePayment(amountUsdc, amountCoin, amountSci);

        ProjectInfo memory projectInfo = ProjectInfo(
            info,
            receivingWallet,
            payment,
            amount,
            sciAmount,
            true // Assuming 'true' indicates the proposal is executable
        );

        uint256 currentIndex = _storeProposal(projectInfo);

        emit Proposed(currentIndex, msg.sender, projectInfo);

        return currentIndex;
    }

    /**
     * @dev vote for an of option of a given proposal
     *      using the rights from the most recent snapshot
     * @param id the index of the proposal
     * @param support true if in support of proposal
     */
    function vote(
        uint256 id,
        bool support
    ) external notTerminated nonReentrant onlyRole(DUE_DILIGENCE_ROLE) {
        //check if proposal exists
        if (id >= _index) revert ProposalInexistent();

        //check if proposal is still active
        if (proposals[id].status != ProposalStatus.Active)
            revert IncorrectPhase(proposals[id].status);

        //check if proposal life time has not passed
        if (block.timestamp > proposals[id].endTimeStamp)
            revert ProposalLifeTimePassed();

        //check if user already voted for this proposal
        if (voted[id][msg.sender] == 1) revert VoteLock();

        IStaking staking = IStaking(stakingAddress);

        //check if DD member/voter still has enough tokens staked
        _validateStakingRequirements(staking, msg.sender);

        //vote for, against or abstain
        if (support) {
            proposals[id].votesFor += VOTE;
        } else {
            proposals[id].votesAgainst += VOTE;
        }

        //add to the total votes
        proposals[id].totalVotes += 1;

        //set user as voted for proposal
        voted[id][msg.sender] = 1;

        //set the lock time in the staking contract
        staking.voted(msg.sender, block.timestamp + voteLockTime);

        //emit Voted events
        emit Voted(id, msg.sender, support, VOTE);
    }

    /**
     * @dev finalizes the voting phase for a research proposal
     * @param id the index of the proposal of interest
     */
    function finalize(
        uint256 id
    ) external notTerminated onlyRole(DUE_DILIGENCE_ROLE) {
        if (id >= _index) revert ProposalInexistent();

        if (proposals[id].status != ProposalStatus.Active)
            revert IncorrectPhase(proposals[id].status);

        if (block.timestamp < proposals[id].endTimeStamp)
            revert ProposalOngoing(
                id,
                block.timestamp,
                proposals[id].endTimeStamp
            );
        if (proposals[id].totalVotes < quorum) revert QuorumNotReached();

        proposals[id].status = ProposalStatus.Scheduled;

        emit Scheduled(id, true);
    }

    /**
     * @dev executes the proposal using USDC
     * @param id the index of the proposal of interest
     * @param donated set to true if funds are derived from the donation wallet
     */
    function execute(
        uint256 id,
        bool donated
    ) external payable notTerminated nonReentrant onlyRole(DUE_DILIGENCE_ROLE) {
        // Check if proposal exists and has finalized voting
        if (id >= _index) revert ProposalInexistent();
        if (proposals[id].status != ProposalStatus.Scheduled)
            revert IncorrectPhase(proposals[id].status);

        // Extract proposal details
        address receivingWallet = proposals[id].details.receivingWallet;
        uint256 amount = proposals[id].details.amount;
        uint256 amountSci = proposals[id].details.amountSci;
        Payment payment = proposals[id].details.payment;

        // Determine the source wallet based on the 'donated' flag
        address sourceWallet = donated ? donationWallet : treasuryWallet;

        // Transfer funds based on payment type
        if (payment == Payment.Usdc || payment == Payment.SciUsdc) {
            _transferToken(IERC20(usdc), sourceWallet, receivingWallet, amount);
        }
        if (payment == Payment.Sci || payment == Payment.SciUsdc) {
            _transferToken(
                IERC20(sci),
                sourceWallet,
                receivingWallet,
                amountSci
            );
        }
        if (payment == Payment.Coin) {
            _transferCoin(sourceWallet, receivingWallet, amount);
        }

        proposals[id].status = ProposalStatus.Executed;
        emit Executed(id, donated, amount);
    }

    /**
     * @dev cancels the proposal
     * @param id the index of the proposal of interest
     */
    function cancel(uint256 id) external nonReentrant notTerminated {
        if (terminated) {
            proposals[id].status = ProposalStatus.Cancelled;

            emit Cancelled(id);
        } else {
            if (id >= _index) revert ProposalInexistent();

            if (proposals[id].status != ProposalStatus.Active)
                revert IncorrectPhase(proposals[id].status);

            proposals[id].status = ProposalStatus.Cancelled;

            emit Cancelled(id);
        }
    }

    /**
     * @dev burns a given amount of SCI tokens for termination
     * @notice DD role members need to unstake their tokens and burn them here
     * @param amount the amount of tokens that will be locked
     */
    function burnForTerminatingResearchFunding(
        uint256 amount
    ) external nonReentrant notTerminated onlyRole(DUE_DILIGENCE_ROLE) {
        ERC20Burnable(sci).burnFrom(msg.sender, amount);

        totBurnedForTermination += amount;

        emit BurnedForTermination(msg.sender, amount);
    }

    /**
     * @dev terminates the governance and staking smart contracts
     */
    function terminateResearchFunding()
        external
        notTerminated
        nonReentrant
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (totBurnedForTermination < terminationThreshold)
            revert BurnThresholdNotReached(
                totBurnedForTermination,
                terminationThreshold
            );
        IStaking staking = IStaking(stakingAddress);
        staking.terminateByGovernance(msg.sender);
        terminated = true;
        emit Terminated(msg.sender, block.number);
    }

    /**
     * @dev returns if user has voted for a given proposal
     * @param id the proposal id
     */
    function getVoted(uint256 id) external view returns (uint8) {
        if (id >= _index) revert ProposalInexistent();
        return voted[id][msg.sender];
    }

    /**
     * @dev returns the proposal index
     */
    function getProposalIndex() external view returns (uint256) {
        return _index;
    }

    /**
     * @notice Retrieves detailed information about a specific governance proposal.
     * @dev This function returns comprehensive details of a proposal identified by its unique ID. It ensures the proposal exists before fetching the details. If the proposal ID is invalid (greater than the current maximum index), it reverts with `ProposalInexistent`.
     * @param id The unique identifier (index) of the proposal whose information is being requested. This ID is sequentially assigned to proposals as they are created.
     * @return startBlockNum The block number at which the proposal was made. This helps in tracking the proposal's lifecycle and duration.
     * @return endTimeStamp The timestamp (block time) by which the proposal voting must be concluded. After this time, the proposal may be finalized or executed based on its status and outcome.
     * @return status The current status of the proposal, represented as a value from the `ProposalStatus` enum. This status could be Active, Scheduled, Executed, Completed, or Cancelled.
     * @return details A `ProjectInfo` struct containing the proposal's detailed information such as the project description (IPFS link), the receiving wallet, payment options, and the amounts involved.
     * @return votesFor The total number of votes in favor of the proposal. This count helps in determining if the proposal has met quorum requirements and the majority's consensus.
     * @return totalVotes The total number of votes cast for the proposal, including both for and against. This is used to calculate the proposal's overall engagement and participation.
     * @return quadraticVoting A boolean indicating whether the proposal uses quadratic voting for determining its outcome. Quadratic voting allows for a more nuanced expression of preference and consensus among voters.
     */
    function getProposalInfo(
        uint256 id
    )
        external
        view
        returns (
            uint256,
            uint256,
            ProposalStatus,
            ProjectInfo memory,
            uint256,
            uint256,
            uint256
        )
    {
        if (id > _index) revert ProposalInexistent();
        return (
            proposals[id].startBlockNum,
            proposals[id].endTimeStamp,
            proposals[id].status,
            proposals[id].details,
            proposals[id].votesFor,
            proposals[id].votesAgainst,
            proposals[id].totalVotes
        );
    }

    ///*** INTERNAL FUNCTIONS ***///

    /**
     * @dev Validates the input parameters for a research proposal.
     * @param info The description or details of the research proposal, expected not to be empty.
     * @param receivingWallet The wallet address that will receive funds if the proposal is approved.
     * @param amountUsdc The amount of USDC tokens involved in the proposal (6 decimals).
     * @param amountCoin The amount of Coin tokens involved in the proposal (18 decimals).
     * @param amountSci The amount of SCI tokens involved in the proposal (18 decimals).
     *
     * @notice This function reverts with InvalidInput if the validation fails.
     * Validation fails if 'info' is empty, 'receivingWallet' is a zero address,
     * or the payment amounts do not meet the specified criteria.
     */
    function _validateInput(
        string memory info,
        address receivingWallet,
        uint256 amountUsdc,
        uint256 amountCoin,
        uint256 amountSci
    ) internal pure {
        bool validInput = bytes(info).length > 0 &&
            receivingWallet != address(0) &&
            ((amountUsdc > 0 && amountCoin == 0) ||
                (amountCoin > 0 && amountUsdc == 0 && amountSci == 0) ||
                (amountSci > 0 && amountCoin == 0));
        if (!validInput) {
            revert InvalidInput();
        }
    }

    /**
     * @dev Validates if the proposer meets the staking requirements for proposing research.
     * @param staking The staking contract interface used to check the staked SCI.
     * @param member The address of the member initiating an action.
     *
     * @notice This function reverts with InsufficientBalance if the staked SCI is below the threshold.
     * The staked SCI amount and required threshold are provided in the revert message.
     */
    function _validateStakingRequirements(
        IStaking staking,
        address member
    ) internal view {
        uint256 stakedSci = staking.getStakedSci(member);
        if (stakedSci < ddThreshold) {
            revert InsufficientBalance(stakedSci, ddThreshold);
        }
    }

    /**
     * @dev Determines the payment method and amount for the research proposal.
     * @param amountUsdc Amount of USDC tokens to be used in the proposal.
     * @param amountCoin Amount of Coin tokens to be used in the proposal.
     * @param amountSci Amount of SCI tokens to be used in the proposal.
     * @return payment The determined type of payment from the Payment enum.
     * @return amount The amount of USDC or Coin tokens to be used.
     * @return sciAmount The amount of SCI tokens to be used.
     *
     * @notice This function reverts with IncorrectPaymentOption if the payment options do not meet the criteria.
     * Only one of amountUsdc, amountCoin, or amountSci should be greater than zero, except for a specific combination
     * where SciUsdc is chosen as the payment method.
     */
    function _determinePayment(
        uint256 amountUsdc,
        uint256 amountCoin,
        uint256 amountSci
    )
        internal
        pure
        returns (Payment payment, uint256 amount, uint256 sciAmount)
    {
        uint8 paymentOptions = (amountUsdc > 0 ? 1 : 0) +
            (amountCoin > 0 ? 1 : 0) +
            (amountSci > 0 ? 1 : 0);

        if (paymentOptions == 1) {
            if (amountUsdc > 0) return (Payment.Usdc, amountUsdc, 0);
            if (amountCoin > 0) return (Payment.Coin, amountCoin, 0);
            if (amountSci > 0) return (Payment.Sci, 0, amountSci);
        } else if (paymentOptions == 2 && amountUsdc > 0 && amountSci > 0) {
            return (Payment.SciUsdc, amountUsdc, amountSci);
        } else {
            revert IncorrectPaymentOption();
        }
    }

    /**
     * @dev Stores a new research proposal in the contract's state.
     * @param projectInfo Struct containing information about the project.
     * @return uint256 The index of the newly stored research proposal.
     *
     * @notice The function increments the _index after storing the proposal.
     * The proposal is stored with an Active status and initialized voting counters.
     * The function returns the index at which the new proposal is stored.
     */
    function _storeProposal(
        ProjectInfo memory projectInfo
    ) internal returns (uint256) {
        Proposal memory proposal = Proposal(
            block.number,
            block.timestamp + proposalLifeTime,
            ProposalStatus.Active,
            projectInfo,
            0,
            0,
            0
        );

        uint256 currentIndex = _index++;
        proposals[currentIndex] = proposal;

        return currentIndex;
    }

    /**
     * @dev Transfers ERC20 tokens from one address to another.
     *      Uses the safeTransferFrom function from the SafeERC20 library
     *      to securely transfer tokens.
     * @param token The ERC20 token to be transferred.
     * @param from The address from which the tokens will be transferred.
     * @param to The address to which the tokens will be transferred.
     * @param amount The amount of tokens to transfer.
     */
    function _transferToken(
        IERC20 token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (amount > 0) {
            token.safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @dev Transfers ETH coin from one address to another.
     *      Requires that the function caller is the same as the 'from' address.
     *      Reverts if the transferred amount does not match the provided value
     *      or if the sender is unauthorized.
     * @param from The address from which the coins will be transferred. Must match the message sender.
     * @param to The address to which the coins will be transferred.
     * @param amount The amount of coins to transfer.
     */
    function _transferCoin(address from, address to, uint256 amount) internal {
        if (msg.sender != from) revert Unauthorized(msg.sender);
        if (msg.value != amount) revert IncorrectCoinValue();
        (bool sent, ) = to.call{value: msg.value}("");
        require(sent, "Failed to transfer");
    }
}
