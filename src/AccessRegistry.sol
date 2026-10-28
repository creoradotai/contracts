// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract AccessRegistry is Ownable {
    bytes32 public merkleRoot;
    mapping(address => bool) public allowlistedAddresses;

    mapping(address => bool) public tokenCreationAllowlistedAddresses;
    mapping(bytes32 => bool) public usedInviteCodes;
    mapping(address => bool) public blockedAddresses;
    bool public allowlistEnabled = true;
    bool public tokenCreationAllowed = true;
    

    event MerkleRootUpdated(bytes32 newMerkleRoot);
    event AddressAllowlisted(address indexed user);
    event AddressRemoved(address indexed user);
    event InviteCodeUsed(bytes32 indexed inviteCode, address indexed user);
    event AllowlistEnabled(bool enabled);
    event AddressBlocked(address indexed user);
    event AddressUnblocked(address indexed user);
    event TokenCreationAllowlisted(address indexed user);
    event TokenCreationRemoved(address indexed user);
    event TokenCreationAllowedSet(bool allowed);

    constructor(bytes32 _initialMerkleRoot) Ownable(msg.sender) {
        merkleRoot = _initialMerkleRoot;
        emit MerkleRootUpdated(_initialMerkleRoot);
    }

    function updateMerkleRoot(bytes32 _newMerkleRoot) external onlyOwner {
        merkleRoot = _newMerkleRoot;
        emit MerkleRootUpdated(_newMerkleRoot);
    }

    function setAllowlistEnabled(bool _enabled) external onlyOwner {
        allowlistEnabled = _enabled;
        emit AllowlistEnabled(_enabled);
    }

    function registerWithInviteCode(bytes32 inviteCodeHash, bytes32[] calldata merkleProof) external {
        require(!usedInviteCodes[inviteCodeHash], "AccessRegistry: Invite code already used");
        
        require(MerkleProof.verify(merkleProof, merkleRoot, inviteCodeHash), "AccessRegistry: Invalid invite code or proof");

        usedInviteCodes[inviteCodeHash] = true;
        allowlistedAddresses[msg.sender] = true;
        
        emit InviteCodeUsed(inviteCodeHash, msg.sender);
        emit AddressAllowlisted(msg.sender);
    }

    function addToAllowlist(address user) external onlyOwner {
        allowlistedAddresses[user] = true;
        emit AddressAllowlisted(user);
    }

    function removeFromAllowlist(address user) external onlyOwner {
        allowlistedAddresses[user] = false;
        emit AddressRemoved(user);
    }

    function isAccessible(address user) external view returns (bool) {
        return !blockedAddresses[user] && (!allowlistEnabled || allowlistedAddresses[user]);   
    }

    function isTokenCreationAllowed(address user) external view returns (bool) {
        return tokenCreationAllowed || (!tokenCreationAllowed && tokenCreationAllowlistedAddresses[user]);
    }

    function setTokenCreationAllowed(bool _allowed) external onlyOwner {
        tokenCreationAllowed = _allowed;
        emit TokenCreationAllowedSet(_allowed);
    }

    function addToTokenCreationAllowlist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            tokenCreationAllowlistedAddresses[users[i]] = true;
            emit TokenCreationAllowlisted(users[i]);
        }
    }
    function removeFromTokenCreationAllowlist(address[] calldata users) external onlyOwner {
        for (uint256 i = 0; i < users.length; i++) {
            tokenCreationAllowlistedAddresses[users[i]] = false;
            emit TokenCreationRemoved(users[i]);
        }
    }
    function blockAddress(address user) external onlyOwner {
        blockedAddresses[user] = true;
        emit AddressBlocked(user);
    }

    function unblockAddress(address user) external onlyOwner {
        blockedAddresses[user] = false;
        emit AddressUnblocked(user);
    }
}