// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract SplitStreamVault is Initializable, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    event Deposit(address indexed from, uint256 amount, uint256 delta);
    event Claim(address indexed account, address indexed to, uint256 amount);
    event WeightsUpdated(
        address[] accounts,
        uint256[] weights,
        uint256 totalWeight
    );
    event Paused();
    event Unpaused();

    bytes32 private constant _CLAIM_TYPEHASH =
        keccak256(
            "Claim(address beneficiary,address to,uint256 nonce,uint256 deadline)"
        );
    bytes32 private _DOMAIN_SEPARATOR;

    IERC20 public token;
    address public guardian;
    address public governor;

    mapping(address => uint256) public weight;
    uint256 public totalWeight;
    uint256 public accPerWeight;
    mapping(address => uint256) public prevAcc;

    mapping(address => uint256) public nonces;

    bool public paused;

    uint256[50] private __gap;

    function initialize(
        IERC20 _token,
        address _guardian,
        address _governor,
        address[] calldata accounts,
        uint256[] calldata weights
    ) external initializer {
        require(accounts.length == weights.length, "length mismatch");

        token = _token;
        guardian = _guardian;
        governor = _governor;

        for (uint256 i; i < accounts.length; ++i) {
            weight[accounts[i]] = weights[i];
            totalWeight += weights[i];
        }

        _updateDomainSeparator();
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        token.safeTransferFrom(msg.sender, address(this), amount);

        uint256 delta = (amount * 1e18) / totalWeight;
        accPerWeight += delta;

        emit Deposit(msg.sender, amount, delta);
    }

    function claim(address to) external nonReentrant whenNotPaused {
        _claimInternal(msg.sender, to);
    }

    function claimWithSig(
        address beneficiary,
        address to,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= deadline, "signature expired");

        uint256 nonce = nonces[beneficiary]++;
        bytes32 structHash = keccak256(
            abi.encode(_CLAIM_TYPEHASH, beneficiary, to, nonce, deadline)
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash)
        );
        require(ecrecover(digest, v, r, s) == beneficiary, "bad signature");

        _claimInternal(beneficiary, to);
    }

    function setWeights(
        address[] calldata accounts,
        uint256[] calldata newWeights
    ) external onlyGovernor {
        require(accounts.length == newWeights.length, "length mismatch");

        for (uint256 i; i < accounts.length; ++i) {
            totalWeight = totalWeight - weight[accounts[i]] + newWeights[i];
            weight[accounts[i]] = newWeights[i];
        }
        emit WeightsUpdated(accounts, newWeights, totalWeight);
    }


    function pause() external onlyGuardian {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused();
    }


    function _authorizeUpgrade(address) internal override onlyGovernor {}


    function _claimInternal(
        address account,
        address to
    ) private returns (uint256 owed) {
        owed = (weight[account] * (accPerWeight - prevAcc[account])) / 1e18;
        prevAcc[account] = accPerWeight;
        token.safeTransfer(to, owed);
        emit Claim(account, to, owed);
    }

    function _updateDomainSeparator() private {
        _DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("SplitStreamVault")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    modifier onlyGuardian() {
        require(msg.sender == guardian, "not guardian");
        _;
    }
    modifier onlyGovernor() {
        require(msg.sender == governor, "not governor");
        _;
    }
    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }
}
