// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

/**
 * @notice Interface for OKX DEX Router (UniswapV2-like)
 */
interface IOKXRouter {
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/**
 * @notice ERC-1155 Access Pass for leases
 */
contract AgentAccessPass is ERC1155, Ownable {
    mapping(uint256 => uint256) public expiryTimestamps;

    constructor() ERC1155("") {}

    function mintPass(address to, uint256 agentId, uint256 leaseId, uint256 expiresAt) external onlyOwner returns (uint256) {
        require(to != address(0), "Invalid recipient");
        require(expiresAt > block.timestamp, "Expiry must be future");
        uint256 tokenId = encodeTokenId(agentId, leaseId);
        expiryTimestamps[tokenId] = expiresAt;
        _mint(to, tokenId, 1, "");
        return tokenId;
    }

    function burnPass(address from, uint256 agentId, uint256 leaseId) external onlyOwner {
        uint256 tokenId = encodeTokenId(agentId, leaseId);
        expiryTimestamps[tokenId] = 0;
        _burn(from, tokenId, 1);
    }

    function isValid(address user, uint256 agentId, uint256 leaseId) public view returns (bool) {
        uint256 tokenId = encodeTokenId(agentId, leaseId);
        return (balanceOf(user, tokenId) > 0 && expiryTimestamps[tokenId] > block.timestamp);
    }

    function encodeTokenId(uint256 agentId, uint256 leaseId) public pure returns (uint256) {
        return (agentId << 128) | leaseId;
    }
}

contract AIAgentLeasingDEX is ERC721URIStorage, Pausable, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _agentIds;
    Counters.Counter private _leaseIds;

    struct Agent {
        address creator;
        string metadataURI;
        uint256 leaseRatePerSecond;
    }

    struct Lease {
        address renter;
        uint256 agentId;
        uint256 expiresAt;
        uint256 totalPricePaid;
        bool active;
    }

    mapping(uint256 => Agent) public agents;
    mapping(uint256 => Lease) public leases;
    mapping(uint256 => uint256[]) private _agentLeaseIds;

    AgentAccessPass public accessPass;
    IOKXRouter public okxRouter;

    event AgentMinted(uint256 indexed agentId, address indexed creator, string metadataURI, uint256 leaseRatePerSecond);
    event LeaseCreated(uint256 indexed leaseId, uint256 indexed agentId, address indexed renter, uint256 expiresAt, uint256 pricePaid);
    event LeaseRevoked(uint256 indexed leaseId, uint256 indexed agentId, address indexed revokedBy);
    event SwapExecuted(
        uint256 indexed agentId,
        uint256 indexed leaseId,
        address indexed executor,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 timestamp
    );

    constructor(address _okxRouter) ERC721("AIAgent", "AIA") {
        // Deploy Access Pass contract
        accessPass = new AgentAccessPass();
        accessPass.transferOwnership(msg.sender);
        okxRouter = IOKXRouter(_okxRouter);
    }

    function mintAgent(string memory metadataURI, uint256 leaseRatePerSecond) external whenNotPaused returns (uint256) {
        require(leaseRatePerSecond > 0, "Lease rate must be > 0");
        _agentIds.increment();
        uint256 newAgentId = _agentIds.current();

        _mint(msg.sender, newAgentId);
        _setTokenURI(newAgentId, metadataURI);

        agents[newAgentId] = Agent({
            creator: msg.sender,
            metadataURI: metadataURI,
            leaseRatePerSecond: leaseRatePerSecond
        });

        emit AgentMinted(newAgentId, msg.sender, metadataURI, leaseRatePerSecond);
        return newAgentId;
    }

    function leaseAgent(uint256 agentId, uint256 durationSeconds) external payable whenNotPaused returns (uint256 leaseId) {
        Agent memory agent = agents[agentId];
        require(agent.creator != address(0), "Agent does not exist");
        require(durationSeconds > 0, "Lease duration must be > 0");

        uint256 price = agent.leaseRatePerSecond * durationSeconds;
        require(msg.value == price, "Incorrect ETH sent for leasing");

        _leaseIds.increment();
        leaseId = _leaseIds.current();

        uint256 expiryTimestamp = block.timestamp + durationSeconds;

        leases[leaseId] = Lease({
            renter: msg.sender,
            agentId: agentId,
            expiresAt: expiryTimestamp,
            totalPricePaid: msg.value,
            active: true
        });

        _agentLeaseIds[agentId].push(leaseId);

        // Mint ERC-1155 access pass to renter
        accessPass.mintPass(msg.sender, agentId, leaseId, expiryTimestamp);

        // Pay the agent owner
        address agentOwner = ownerOf(agentId);
        (bool sent, ) = payable(agentOwner).call{value: msg.value}("");
        require(sent, "Failed to forward lease payment");

        emit LeaseCreated(leaseId, agentId, msg.sender, expiryTimestamp, msg.value);
    }

    function revokeLease(uint256 leaseId) external whenNotPaused {
        Lease storage lease = leases[leaseId];
        require(lease.active, "Lease inactive");
        require(ownerOf(lease.agentId) == msg.sender, "Only agent owner can revoke");

        lease.active = false;
        accessPass.burnPass(lease.renter, lease.agentId, leaseId);

        emit LeaseRevoked(leaseId, lease.agentId, msg.sender);
    }

    function isLeaseValid(uint256 agentId, uint256 leaseId, address user) public view returns (bool) {
        if (!leases[leaseId].active) return false;
        return accessPass.isValid(user, agentId, leaseId);
    }

    /**
     * @notice Execute an OKX DEX swap, only callable by agent owner or active lease pass holder.
     * @param agentId The AI agent NFT ID.
     * @param leaseId The lease ID (0 if agent owner calls directly).
     * @param amountIn Amount of tokenIn to swap.
     * @param amountOutMin Slippage protection.
     * @param path Swap path (tokenIn => tokenOut).
     * @param recipient Recipient of output tokens.
     */
    function executeSwap(
        uint256 agentId,
        uint256 leaseId,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address recipient,
        uint256 deadline
    ) external whenNotPaused returns (uint[] memory amounts) {
        require(path.length >= 2, "Invalid path");
        require(recipient != address(0), "Recipient cannot be zero");
        bool isOwner = (ownerOf(agentId) == msg.sender);

        if (!isOwner) {
            require(isLeaseValid(agentId, leaseId, msg.sender), "Not authorized to execute swaps");
        } else {
            require(leaseId == 0, "Owners must use leaseId=0");
        }

        // Transfer tokenIn from sender to contract (must approve first)
        address tokenIn = path[0];
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "TokenIn transfer failed");

        // Approve router to spend tokenIn
        if (IERC20(tokenIn).allowance(address(this), address(okxRouter)) < amountIn) {
            IERC20(tokenIn).approve(address(okxRouter), type(uint256).max);
        }

        // Call OKX router for actual swap
        amounts = okxRouter.swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            recipient,
            deadline
        );

        emit SwapExecuted(
            agentId,
            leaseId,
            msg.sender,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            block.timestamp
        );
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function getAgent(uint256 agentId) external view returns (Agent memory) { return agents[agentId]; }
    function getLease(uint256 leaseId) external view returns (Lease memory) { return leases[leaseId]; }
    function getAgentLeaseIds(uint256 agentId) external view returns (uint256[] memory) { return _agentLeaseIds[agentId]; }
    function getAccessPassContract() external view returns (address) { return address(accessPass); }
}
