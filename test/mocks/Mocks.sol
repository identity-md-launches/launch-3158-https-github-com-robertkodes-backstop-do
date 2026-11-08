// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) public virtual returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Burns 1 % of every transfer.
contract FeeOnTransferToken is MockERC20 {
    constructor() MockERC20("Fee", "FEE", 18) {}

    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// @notice Can block transfers to one address (a blacklisting token like USDC).
contract BlockingToken is MockERC20 {
    address public blocked;

    constructor() MockERC20("Block", "BLK", 6) {}

    function setBlocked(address who) external {
        blocked = who;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(to != blocked, "blocked");
        super._move(from, to, amount);
    }
}

/// @notice On an outbound transfer, calls back into `target` with `data` once and records the result.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public data;
    bool public armed;
    bool public attempted;
    bytes public reentryResult;

    constructor() MockERC20("Re", "RE", 18) {}

    function arm(address target_, bytes calldata data_) external {
        target = target_;
        data = data_;
        armed = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _move(msg.sender, to, amount);
        if (armed && msg.sender == target) {
            armed = false;
            attempted = true;
            (, bytes memory ret) = target.call(data);
            reentryResult = ret;
        }
        return true;
    }
}

/// @notice Uniswap v3 pool stand-in: returns cumulatives for a fixed past and present mean tick.
contract MockPool {
    address public token0;
    address public token1;
    int24 public tickPast;
    int24 public tickNow;
    bool public broken;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setTicks(int24 past, int24 now_) external {
        tickPast = past;
        tickNow = now_;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory l) {
        require(!broken, "OLD");
        require(secondsAgos.length == 4, "len");
        uint32 w = secondsAgos[2];
        uint32 gap = secondsAgos[1] - secondsAgos[2];
        c = new int56[](4);
        l = new uint160[](4);
        c[0] = 1_000_000;
        c[1] = c[0] + int56(tickPast) * int56(uint56(w));
        c[2] = c[1] + int56(tickNow) * int56(uint56(gap > w ? gap - w : 0));
        c[3] = c[2] + int56(tickNow) * int56(uint56(w));
    }
}
