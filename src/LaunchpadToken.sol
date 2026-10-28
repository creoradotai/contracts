// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

import {Gauge} from "./Gauge.sol";

contract LaunchpadToken is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable {
    Gauge public gauge;
    address public router;

    string public ipfsHash;
    string public website;
    string public twitter;
    string public telegram;
    string public description;
    string public metadata;

    constructor() {
        _disableInitializers();
    }

    struct TokenConfig {
        string name;
        string symbol;
    }

    struct TokenMetadataConfig {
        string ipfsHash;
        string website;
        string twitter;
        string telegram;
        string description;
        string metadata;
    }

    function initialize(
        TokenConfig memory _tokenConfig,
        TokenMetadataConfig memory _metadataConfig,
        address _gauge,
        uint256 _initialSupply
    ) external initializer {
        __ERC20_init(_tokenConfig.name, _tokenConfig.symbol);
        __ERC20Permit_init(_tokenConfig.name);

        if (_gauge == address(0)) revert LaunchpadToken__ZeroAddress();
        gauge = Gauge(payable(_gauge));
        router = msg.sender;

        ipfsHash = _metadataConfig.ipfsHash;
        website = _metadataConfig.website;
        twitter = _metadataConfig.twitter;
        telegram = _metadataConfig.telegram;
        description = _metadataConfig.description;
        metadata = _metadataConfig.metadata;

        _mint(msg.sender, _initialSupply);
    }

    function _update(address from, address to, uint256 value) internal override {
        Gauge _gauge = gauge;
        if (address(_gauge) != address(0) && _gauge.gaugeActive() && to == address(_gauge.poolManager())) {
            revert LaunchpadToken__TransferRestricted();
        }
        super._update(from, to, value);
    }

    function getAllMetadata() external view returns (TokenMetadataConfig memory) {
        return TokenMetadataConfig({
            ipfsHash: ipfsHash,
            website: website,
            twitter: twitter,
            telegram: telegram,
            description: description,
            metadata: metadata
        });
    }

    error LaunchpadToken__ZeroAddress();
    error LaunchpadToken__TransferRestricted();
}
