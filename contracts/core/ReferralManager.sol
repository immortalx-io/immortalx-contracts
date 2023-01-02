// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../access/Governable.sol";

contract ReferralManager is Governable {
    struct Tier {
        uint256 referrerRebate;
        uint256 traderRebate;
    }

    uint256 public constant BASIS_POINTS = 10000;

    mapping(bytes32 => address) public codeOwners;
    mapping(address => bytes32) public traderCodes;
    mapping(uint256 => Tier) public tiers;
    mapping(address => uint256) public referrerTiers;
    mapping(address => bool) public isAdmin;

    event CreateCode(address account, bytes32 code);
    event UseCode(address account, bytes32 code);
    event ChangeCodeOwner(address account, address newAccount, bytes32 code);
    event SetTier(uint256 tierNum, uint256 referrerRebate, uint256 traderRebate);
    event SetReferrerTier(address referrer, uint256 tierNum);

    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "ReferralManager: forbidden");
        _;
    }

    constructor() {
        isAdmin[msg.sender] = true;

        setTier(0, 500, 500);
        setTier(1, 1000, 1000);
        setTier(2, 1000, 1500);
    }

    function createCode(bytes32 _code) external {
        require(_code != bytes32(0), "ReferralManager: invalid _code");
        require(codeOwners[_code] == address(0), "ReferralManager: code already exists");

        codeOwners[_code] = msg.sender;
        emit CreateCode(msg.sender, _code);
    }

    function useCode(bytes32 _code) external {
        require(codeOwners[_code] != address(0), "ReferralManager: code does not exist");

        traderCodes[msg.sender] = _code;
        emit UseCode(msg.sender, _code);
    }

    function changeCodeOwner(bytes32 _code, address _newAccount) external {
        require(_code != bytes32(0), "ReferralManager: invalid _code");
        require(msg.sender == codeOwners[_code], "ReferralManager: forbidden");

        codeOwners[_code] = _newAccount;
        emit ChangeCodeOwner(msg.sender, _newAccount, _code);
    }

    function getReferrerInfo(address _account)
        external
        view
        returns (
            address,
            uint256,
            uint256
        )
    {
        bytes32 code = traderCodes[_account];

        if (code == bytes32(0)) {
            return (address(0), 0, 0);
        }

        address referrer = codeOwners[code];

        return (referrer, tiers[referrerTiers[referrer]].referrerRebate, tiers[referrerTiers[referrer]].traderRebate);
    }

    function setReferrerTier(address _referrer, uint256 _tierNum) external onlyAdmin {
        referrerTiers[_referrer] = _tierNum;

        emit SetReferrerTier(_referrer, _tierNum);
    }

    function setTier(
        uint256 _tierNum,
        uint256 _referrerRebate,
        uint256 _traderRebate
    ) public onlyGov {
        require(_referrerRebate + _traderRebate < BASIS_POINTS, "ReferralManager: invalid rebate");

        tiers[_tierNum].referrerRebate = _referrerRebate;
        tiers[_tierNum].traderRebate = _traderRebate;

        emit SetTier(_tierNum, _referrerRebate, _traderRebate);
    }

    function setAdmin(address _admin, bool _isActive) external onlyGov {
        isAdmin[_admin] = _isActive;
    }
}
