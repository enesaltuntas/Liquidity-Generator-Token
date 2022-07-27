// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import "./Pancakeswap.sol";

contract LiquidityToken is 
    ERC20, ERC20Permit, 
    ERC20Capped, ERC20Burnable,
    Ownable, AccessControl {

  using SafeMath for uint256;

  IPancakeSwapV2Router02 private PancakeSwapV2Router;
  address private PancakeSwapV2Pair;

  bytes32 private constant BLACKLIST_ROLE = 0x0000000000000000000000000000000000000000000000000000000000000100;

  bool projectInitialized;
 
  uint256 public maxSupply = 10 * 10**9 * 10 ** decimals();
  uint256 private _totalSupply;
  uint256 public swapThreshold;
  bool public swapEnabled;

  bool sniperTax;
  bool tradingEnabled;
  bool inSwap;

  uint256 public buyTax;
  uint256 public sellTax;
  uint256 public transferTax;

  uint256 public liquidityShare;
  uint256 public marketingShare;
  uint256 constant TAX_DENOMINATOR=100;
  uint256 totalShares;

  uint256 public transferGas;
  uint256 public launchTime;

  address marketingWallet;

  mapping (address => bool) public isWhitelisted;
  mapping (address => bool) public isCEX;
  mapping (address => bool) public isMarketMaker;

  event ProjectInitialized(bool completed);
  event EnableTrading();
  event SniperTaxRemoved();
  event TriggerSwapBack();
  event Burn(address account, uint256 amount);
  event RecoverBNB(uint256 amount);
  event RecoverBEP20(address indexed token, uint256 amount);
  event UpdateMarketingWallet(address newWallet, address oldWallet);
  event UpdateGasForProcessing(uint256 indexed newValue, uint256 indexed oldValue);
  event SetWhitelisted(address indexed account, bool indexed status);
  event SetCEX(address indexed account, bool indexed exempt);
  event SetMarketMaker(address indexed account, bool indexed isMM);
  event SetTaxes(uint256 buy, uint256 sell, uint256 transfer);
  event SetShares(uint256 liquidityShare, uint256 marketingShare);
  event SetSwapBackSettings(bool enabled, uint256 amount);
  event AutoLiquidity(uint256 PancakeSwapV2Pair, uint256 tokens);
  event DepositMarketing(address indexed wallet, uint256 amount);
  event SetTransferGas(uint256 newValue);

  modifier swapping() {
    inSwap = true;
    _;
    inSwap = false;
  }

  constructor () 
    ERC20("LiquidityToken", "LQT")
    ERC20Permit("LiquidityToken")
    ERC20Capped(maxSupply)
    {
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    buyTax = 5;
    sellTax = 5;
    transferTax = 0;
    liquidityShare = 35;
    marketingShare = 65;
    totalShares = 100;
    swapThreshold = 5000 * 10**decimals();
    swapEnabled = true;
    sniperTax = true;
    transferGas = 30000;
    marketingWallet = address(0x5A8140574d12C65F73311fa05E44B93b3ca2Cca6);
    _mint(address(msg.sender), maxSupply);
  }

    receive() external payable {}

    function _mint(address account, uint256 amount) internal virtual override(ERC20, ERC20Capped) {
      ERC20Capped._mint(account, amount);
    }

    function _revokeRole(bytes32 role, address account) internal virtual override {
        require(msg.sender == owner(),"permErr");
        super._revokeRole(role,account);
    }

    function initializeProject() external onlyOwner {
        require(!projectInitialized);

        // MN: 0x10ED43C718714eb63d5aA57B78B54704E256024E
        // TN: 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3

        IPancakeSwapV2Router02 _pancakeSwapV2Router = IPancakeSwapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        address _pancakeSwapV2Pair = IPancakeSwapV2Factory(_pancakeSwapV2Router.factory())
        .createPair(address(this), _pancakeSwapV2Router.WETH());

        PancakeSwapV2Router = _pancakeSwapV2Router;
        PancakeSwapV2Pair = _pancakeSwapV2Pair;

        _approve(address(this), address(PancakeSwapV2Router), type(uint256).max);

        isMarketMaker[PancakeSwapV2Pair] = true;
        isWhitelisted[owner()] = true;
        projectInitialized = true;
        emit ProjectInitialized(true);

    }

    // Override
    function _transfer(address sender, address recipient, uint256 amount) internal override {

        require(hasRole(BLACKLIST_ROLE, sender) == false && hasRole(BLACKLIST_ROLE, recipient) == false, "BL");

        if (isWhitelisted[sender] || isWhitelisted[recipient] || inSwap) {
            super._transfer(sender, recipient, amount);
            return;
        }

        require(tradingEnabled);

        if (_shouldSwapBack(isMarketMaker[recipient])) { _swapBack(); }

        uint256 amountAfterTaxes = _takeTax(sender, recipient, amount);

        super._transfer(sender, recipient, amountAfterTaxes);

    }

    function _takeTax(address sender, address recipient, uint256 amount) private returns (uint256) {

        if (amount == 0) { return amount; }

        uint256 tax = _getTotalTax(sender, recipient);

        uint256 taxAmount = amount * tax / TAX_DENOMINATOR;

        if (taxAmount > 0) { super._transfer(sender, address(this), taxAmount); }

        return amount - taxAmount;

    }

    function _getTotalTax(address sender, address recipient) private view returns (uint256) {

        if (sniperTax) { return 99; }
        if (isCEX[recipient]) { return sellTax; }
        if (isCEX[sender]) { return buyTax; }

        if (isMarketMaker[sender]) {
            return buyTax;
        } else if (isMarketMaker[recipient]) {
            return sellTax;
        } else {
            return transferTax;
        }

    }

    function _shouldSwapBack(bool run) private view returns (bool) {
        return swapEnabled && run && balanceOf(address(this)) >= swapThreshold;
    }

    function _swapBack() private swapping {

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = PancakeSwapV2Router.WETH();

        uint256 liquidityTokens = swapThreshold * liquidityShare / totalShares / 2;
        uint256 amountToSwap = swapThreshold - liquidityTokens;
        uint256 balanceBefore = address(this).balance;

        PancakeSwapV2Router.swapExactTokensForETH(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountBNB = address(this).balance - balanceBefore;
        uint256 totalBNBShares = totalShares - liquidityShare / 2;

        uint256 amountBNBLiquidity = amountBNB * liquidityShare / totalBNBShares / 2;
        uint256 amountBNBMarketing = amountBNB * marketingShare / totalBNBShares;

        (bool marketingSuccess,) = payable(marketingWallet).call{value: amountBNBMarketing, gas: transferGas}("");
        if (marketingSuccess) { emit DepositMarketing(marketingWallet, amountBNBMarketing); }

        if (liquidityTokens > 0) {

            PancakeSwapV2Router.addLiquidityETH{value: amountBNBLiquidity}(
                address(this),
                liquidityTokens,
                0,
                0,
                address(this),
                block.timestamp
            );

            emit AutoLiquidity(amountBNBLiquidity, liquidityTokens);

        }

    }

    // Owner

    function removeSniperTax() external onlyOwner {
        sniperTax = false;
        emit SniperTaxRemoved();
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled);
        tradingEnabled = true;
        launchTime = block.timestamp;
        emit EnableTrading();
    }

    function triggerSwapBack() external onlyOwner {
        _swapBack();
        emit TriggerSwapBack();
    }

    function recoverBNB() external onlyOwner {
        uint256 amount = address(this).balance;
        (bool sent,) = payable(marketingWallet).call{value: amount, gas: transferGas}("");
        require(sent, "Tx failed");
        emit RecoverBNB(amount);
    }

    function recoverBEP20(IERC20 token, address recipient) external onlyOwner {
        require(address(token) != address(this), "Can't withdraw");
        uint256 amount = token.balanceOf(address(this));
        token.transfer(recipient, amount);
        emit RecoverBEP20(address(token), amount);
    }

    function setIsWhitelisted(address account, bool value) external onlyOwner {
        isWhitelisted[account] = value;
        emit SetWhitelisted(account, value);
    }

    function setIsCEX(address account, bool value) external onlyOwner {
        isCEX[account] = value;
        emit SetCEX(account, value);
    }

    function setIsMarketMaker(address account, bool value) external onlyOwner {
        require(account != PancakeSwapV2Pair);
        isMarketMaker[account] = value;
        emit SetMarketMaker(account, value);
    }


    function setTaxes(uint256 newBuyTax, uint256 newSellTax, uint256 newTransferTax) external onlyOwner {
        require(newBuyTax <= 10 && newSellTax <= 20 && newTransferTax <= 10);
        buyTax = newBuyTax;
        sellTax = newSellTax;
        transferTax = newTransferTax;
        emit SetTaxes(buyTax, sellTax, transferTax);
    }

    function setShares(uint256 newLiquidityShare, uint256 newMarketingShare) external onlyOwner {
        liquidityShare = newLiquidityShare;
        marketingShare = newMarketingShare;
        totalShares = liquidityShare + marketingShare;
        emit SetShares(liquidityShare, marketingShare);
    }

    function setSwapBackSettings(bool enabled, uint256 amount) external onlyOwner {
        uint256 tokenAmount = amount * 10**decimals();
        swapEnabled = enabled;
        swapThreshold = tokenAmount;
        emit SetSwapBackSettings(enabled, amount);
    }

    function setTransferGas(uint256 newGas) external onlyOwner {
        require(newGas >= 25000 && newGas <= 500000);
        transferGas = newGas;
        emit SetTransferGas(newGas);
    }

    function setMarketingWallet(address newWallet) external onlyOwner {
        require(newWallet != address(0));
        address oldWallet = marketingWallet;
        marketingWallet = newWallet;
        emit UpdateMarketingWallet(newWallet,oldWallet);
    }

}
