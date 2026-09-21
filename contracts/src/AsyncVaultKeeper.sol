// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { VaultKeeper } from "./VaultKeeper.sol";
import { IVaultKeeper, IStockPriceFeed, TransferMode } from "./interfaces/IVaultKeeper.sol";

// ============================================================================
//  AsyncVaultKeeper — ERC-7540 (asynchronous ERC-4626) vault
// ============================================================================
//
//  Why: the synchronous vault prices a deposit and issues shares in one
//  transaction. When the portfolio is a basket of tokenised equities marked by an
//  oracle and traded on a DEX, that is exactly what you do not want: a large deposit
//  is priced off a quote the vault may not be able to trade against, and a large exit
//  can be front-run into the reference feed. ERC-7540 splits both flows into a
//  *request* (recorded, assets in, no price exposure decided yet) and a *claim* (the
//  vault has processed it and the user pulls the result).
//
//  This contract is a thin, fully asynchronous layer over {VaultKeeper}:
//
//    • requestDeposit / requestRedeem  — enter or leave the queue.
//    • fulfillDeposits / fulfillRedeems — keeper- or owner-driven processing
//      (pending -> claimable). FulfillmentMode.INSTANT short-circuits this.
//    • deposit / mint / withdraw / redeem — the ERC-4626 entrypoints become *claim*
//      functions, exactly as the standard prescribes.
//
//  Accounting choice (this is the important part):
//    Every asset held on behalf of a request — pending *or* claimable — is excluded
//    from {totalAssets}. The share price is therefore untouched by a request, and a
//    claim converts at the price prevailing when it is claimed:
//
//      request deposit :  assets in, NAV unchanged          -> price unchanged
//      request redeem  :  shares burned, NAV -= snapshot     -> price unchanged
//      claim deposit   :  shares minted at the live price    -> price unchanged
//      claim redeem    :  snapshot paid out, NAV unchanged   -> price unchanged
//
//    The depositor carries the price risk between request and claim (the standard
//    permits this explicitly), while the redeemer's payout is fixed at request time
//    (pending redemptions are not yield-bearing, also explicitly permitted).
//
//  ERC-7540 support:
//    • ERC-165: 0xe3bc4e65 (operators), 0xce3bbe50 (async deposit),
//      0x620ee8e4 (async redeem), 0x2f0a18c5 (ERC-7575).
//    • requestId: always 0 — the aggregate mode, where request state is discriminated
//      by controller alone. All pending/claimable amounts for one controller net into
//      a single queue position.
// ============================================================================

/// @title AsyncVaultKeeper
/// @notice Fully asynchronous ERC-7540 vault: deposits and redemptions are requested,
///         processed by the keeper, then claimed.
contract AsyncVaultKeeper is VaultKeeper, IERC165 {
    using SafeERC20 for IERC20;

    // ────────────────────────────────────────────────────────────────────────
    //  Constants
    // ────────────────────────────────────────────────────────────────────────

    /// @notice ERC-165 interface ids mandated by ERC-7540 / ERC-7575.
    bytes4 public constant INTERFACE_ERC7540_OPERATOR = 0xe3bc4e65;
    bytes4 public constant INTERFACE_ERC7540_DEPOSIT = 0xce3bbe50;
    bytes4 public constant INTERFACE_ERC7540_REDEEM = 0x620ee8e4;
    bytes4 public constant INTERFACE_ERC7575 = 0x2f0a18c5;

    /// @notice The only request id this vault ever returns (aggregate mode).
    uint256 public constant REQUEST_ID = 0;

    // ────────────────────────────────────────────────────────────────────────
    //  Types
    // ────────────────────────────────────────────────────────────────────────

    /// @notice How a request becomes claimable.
    enum FulfillmentMode {
        /// @dev The owner or keeper must call {fulfillDeposits} / {fulfillRedeems}.
        MANUAL,
        /// @dev Requests are claimable immediately on submission.
        INSTANT
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Events
    // ────────────────────────────────────────────────────────────────────────

    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    event DepositRequestFulfilled(address indexed controller, uint256 assets);
    event RedeemRequestFulfilled(address indexed controller, uint256 shares, uint256 assets);
    event FulfillmentModeUpdated(FulfillmentMode oldMode, FulfillmentMode newMode);

    // ────────────────────────────────────────────────────────────────────────
    //  Errors
    // ────────────────────────────────────────────────────────────────────────

    error PreviewNotSupported();
    error NotController(address controller, address caller);
    error InsufficientClaimable(address controller, uint256 requested, uint256 available);
    error NothingToFulfill(address controller);

    // ────────────────────────────────────────────────────────────────────────
    //  State
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Request processing mode.
    FulfillmentMode public fulfillmentMode;

    /// @notice ERC-7540 operator approvals: controller => operator => approved.
    mapping(address controller => mapping(address operator => bool approved)) public isOperator;

    struct RequestState {
        uint256 pendingAssets;
        uint256 claimableAssets;
        uint256 pendingShares;
        /// @dev Assets owed for the pending redemption, snapshotted at request time.
        uint256 pendingRedeemAssets;
        uint256 claimableShares;
        /// @dev Assets owed for the claimable redemption, snapshotted at request time.
        uint256 claimableRedeemAssets;
    }

    mapping(address controller => RequestState) private _requests;

    /// @notice Deposited assets still waiting to be processed. Excluded from NAV.
    uint256 public totalPendingDeposits;

    /// @notice Deposited assets processed and awaiting claim. Excluded from NAV.
    uint256 public totalClaimableDeposits;

    /// @notice Assets owed for redemptions still waiting to be processed. Excluded from NAV.
    uint256 public totalPendingRedeemAssets;

    /// @notice Assets owed for redemptions awaiting claim. Excluded from NAV.
    uint256 public totalClaimableRedeemAssets;

    // ────────────────────────────────────────────────────────────────────────
    //  Construction
    // ────────────────────────────────────────────────────────────────────────

    constructor(
        string memory name_,
        string memory symbol_,
        address depositAsset_,
        address priceFeed_,
        address uniRouter_,
        IVaultKeeper.Strategy memory strategy_,
        address initialOwner
    ) VaultKeeper(name_, symbol_, depositAsset_, priceFeed_, uniRouter_, strategy_, initialOwner) { }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-4626 accounting — requests are held outside the pool
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Subtracts everything held for a request. See the contract-level note.
    function totalAssets() public view virtual override returns (uint256) {
        uint256 base = super.totalAssets();
        uint256 held =
            totalPendingDeposits + totalClaimableDeposits + totalPendingRedeemAssets + totalClaimableRedeemAssets;
        unchecked {
            return base > held ? base - held : 0;
        }
    }

    /// @dev The rebalancer must not trade with money that is owed to a claimant.
    function _reservedCash() internal view virtual override returns (uint256) {
        return super._reservedCash() + totalPendingDeposits + totalClaimableDeposits + totalPendingRedeemAssets
            + totalClaimableRedeemAssets;
    }

    /// @dev Advances the fee clock and refreshes the price used to convert a claim.
    function _assessFeesBeforeClaim() internal {
        _assessFees();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Limits
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Requests are always accepted (subject to the pause); the *claim* is what the
    ///      claimable amount bounds. `maxWithdraw`/`maxRedeem` therefore report the
    ///      processed balance, per ERC-7540.
    function maxDeposit(address) public view virtual override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxMint(address) public view virtual override returns (uint256) {
        return paused ? 0 : type(uint256).max;
    }

    function maxWithdraw(address controller) public view virtual override returns (uint256) {
        if (paused) return 0;
        return _requests[controller].claimableRedeemAssets;
    }

    function maxRedeem(address controller) public view virtual override returns (uint256) {
        if (paused) return 0;
        return _requests[controller].claimableShares;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-7540 — request flows
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Queues a deposit of `assets`, taken from `owner`, for `controller`.
    /// @dev `owner` must be `msg.sender` or have approved `msg.sender` as an operator.
    ///      Assets move into the vault immediately but are excluded from NAV until claimed.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (owner == address(0) || controller == address(0)) revert ZeroAddress();
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotController(owner, msg.sender);
        if (assets == 0) revert ZeroAmount();

        // ERC-7540: the request may be placed by an approved operator; `owner` is the
        // share holder and has authorised this pull through its own ERC-20 allowance.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        depositAsset.safeTransferFrom(owner, address(this), assets);

        RequestState storage req = _requests[controller];
        if (fulfillmentMode == FulfillmentMode.INSTANT) {
            req.claimableAssets += assets;
            totalClaimableDeposits += assets;
        } else {
            req.pendingAssets += assets;
            totalPendingDeposits += assets;
        }

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    /// @notice Queues a redemption of `shares`, taken from `owner`, for `controller`.
    /// @dev Shares are burned on request, per ERC-7540, and the payout is snapshotted at
    ///      the price prevailing now.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (owner == address(0) || controller == address(0)) revert ZeroAddress();
        if (shares == 0) revert ZeroAmount();

        // Either an operator approval or an ERC-20 allowance authorises taking the shares.
        if (owner != msg.sender && !isOperator[owner][msg.sender]) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 assets = super.previewRedeem(shares); // price *before* the burn

        RequestState storage req = _requests[controller];
        if (fulfillmentMode == FulfillmentMode.INSTANT) {
            req.claimableShares += shares;
            req.claimableRedeemAssets += assets;
            totalClaimableRedeemAssets += assets;
        } else {
            req.pendingShares += shares;
            req.pendingRedeemAssets += assets;
            totalPendingRedeemAssets += assets;
        }

        _burn(owner, shares);

        emit RedeemRequest(controller, owner, REQUEST_ID, msg.sender, shares);
        return REQUEST_ID;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-7540 — request views (requestId is ignored: aggregate mode)
    // ────────────────────────────────────────────────────────────────────────

    function pendingDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        return _requests[controller].pendingAssets;
    }

    function claimableDepositRequest(uint256, address controller) external view returns (uint256 assets) {
        return _requests[controller].claimableAssets;
    }

    function pendingRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        return _requests[controller].pendingShares;
    }

    function claimableRedeemRequest(uint256, address controller) external view returns (uint256 shares) {
        return _requests[controller].claimableShares;
    }

    /// @notice Assets owed to `controller` for its claimable redemption, snapshotted at
    ///         request time. Required by {withdraw}-style claims.
    function claimableRedeemAssets(address controller) external view returns (uint256 assets) {
        return _requests[controller].claimableRedeemAssets;
    }

    /// @notice Everything queued for `controller`, in one call.
    function requestState(address controller) external view returns (RequestState memory) {
        return _requests[controller];
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-7540 — operators
    // ────────────────────────────────────────────────────────────────────────

    function setOperator(address operator, bool approved) external returns (bool success) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Fulfillment (pending -> claimable)
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Processes queued deposit requests so the controllers can claim shares.
    function fulfillDeposits(address[] calldata controllers) external nonReentrant onlyKeeperOrOwner {
        uint256 len = controllers.length;
        for (uint256 i; i < len; ++i) {
            address controller = controllers[i];
            uint256 assets = _requests[controller].pendingAssets;
            if (assets == 0) revert NothingToFulfill(controller);

            _requests[controller].pendingAssets = 0;
            _requests[controller].claimableAssets += assets;
            totalPendingDeposits -= assets;
            totalClaimableDeposits += assets;

            emit DepositRequestFulfilled(controller, assets);
        }
    }

    /// @notice Processes queued redemption requests so the controllers can claim assets.
    function fulfillRedeems(address[] calldata controllers) external nonReentrant onlyKeeperOrOwner {
        uint256 len = controllers.length;
        for (uint256 i; i < len; ++i) {
            address controller = controllers[i];
            RequestState storage req = _requests[controller];
            uint256 shares = req.pendingShares;
            if (shares == 0) revert NothingToFulfill(controller);

            uint256 assets = req.pendingRedeemAssets;
            req.pendingShares = 0;
            req.pendingRedeemAssets = 0;
            req.claimableShares += shares;
            req.claimableRedeemAssets += assets;
            totalPendingRedeemAssets -= assets;
            totalClaimableRedeemAssets += assets;

            emit RedeemRequestFulfilled(controller, shares, assets);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-4626 entrypoints — now claim functions
    // ────────────────────────────────────────────────────────────────────────

    /// @dev Claims `assets` of the caller's claimable deposit for `receiver`.
    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        return _claimDeposit(assets, receiver, msg.sender);
    }

    /// @notice ERC-7540 overload: claim on behalf of `controller`.
    function deposit(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _requireControllerOrOperator(controller);
        return _claimDeposit(assets, receiver, controller);
    }

    function mint(uint256 shares, address receiver)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        return _claimMint(shares, receiver, msg.sender);
    }

    /// @notice ERC-7540 overload: claim on behalf of `controller`.
    function mint(uint256 shares, address receiver, address controller)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        _requireControllerOrOperator(controller);
        return _claimMint(shares, receiver, controller);
    }

    /// @dev `owner_` is the ERC-7540 `controller`.
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        _requireControllerOrOperator(owner_);
        return _claimWithdraw(assets, receiver, owner_);
    }

    /// @dev `owner_` is the ERC-7540 `controller`.
    function redeem(uint256 shares, address receiver, address owner_)
        public
        virtual
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        _requireControllerOrOperator(owner_);
        return _claimRedeem(shares, receiver, owner_);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-7540 — previews must revert
    // ────────────────────────────────────────────────────────────────────────

    /// @dev ERC-7540: "previewDeposit and previewMint MUST revert for all callers and inputs"
    ///      on an asynchronous deposit vault: the exchange rate is not knowable before the
    ///      request is claimed.
    function previewDeposit(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @dev See {previewDeposit}.
    function previewMint(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @dev ERC-7540: redemption previews revert for the same reason.
    function previewRedeem(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    /// @dev See {previewRedeem}.
    function previewWithdraw(uint256) public pure override returns (uint256) {
        revert PreviewNotSupported();
    }

    // ────────────────────────────────────────────────────────────────────────
    //  ERC-165 / ERC-7575
    // ────────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == INTERFACE_ERC7540_OPERATOR
            || interfaceId == INTERFACE_ERC7540_DEPOSIT || interfaceId == INTERFACE_ERC7540_REDEEM
            || interfaceId == INTERFACE_ERC7575;
    }

    /// @notice ERC-7575: the share token is this contract itself.
    function share() external view returns (address) {
        return address(this);
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Governance
    // ────────────────────────────────────────────────────────────────────────

    /// @notice Switches request processing between manual and instant.
    function setFulfillmentMode(FulfillmentMode mode) external onlyOwner {
        FulfillmentMode old = fulfillmentMode;
        fulfillmentMode = mode;
        emit FulfillmentModeUpdated(old, mode);
    }

    /// @notice Processes the caller's own pending requests, so a user is never blocked by a
    ///         keeper that is offline when the mode is manual.
    function selfFulfill() external nonReentrant {
        RequestState storage req = _requests[msg.sender];

        if (req.pendingAssets != 0) {
            uint256 assets = req.pendingAssets;
            req.pendingAssets = 0;
            req.claimableAssets += assets;
            totalPendingDeposits -= assets;
            totalClaimableDeposits += assets;
            emit DepositRequestFulfilled(msg.sender, assets);
        }

        if (req.pendingShares != 0) {
            uint256 shares = req.pendingShares;
            uint256 assets = req.pendingRedeemAssets;
            req.pendingShares = 0;
            req.pendingRedeemAssets = 0;
            req.claimableShares += shares;
            req.claimableRedeemAssets += assets;
            totalPendingRedeemAssets -= assets;
            totalClaimableRedeemAssets += assets;
            emit RedeemRequestFulfilled(msg.sender, shares, assets);
        }
    }

    // ────────────────────────────────────────────────────────────────────────
    //  Internals
    // ────────────────────────────────────────────────────────────────────────

    function _requireControllerOrOperator(address controller) internal view {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) {
            revert NotController(controller, msg.sender);
        }
    }

    /// @dev Mints shares against already-held claimable assets. The asset transfer happened
    ///      at request time, so the ERC-4626 `_deposit` hook (which would pull assets again)
    ///      is deliberately bypassed in favour of the fee/HWM bookkeeping it also performs.
    function _claimDeposit(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        RequestState storage req = _requests[controller];
        uint256 available = req.claimableAssets;
        if (assets == 0 || assets > available) revert InsufficientClaimable(controller, assets, available);

        _assessFeesBeforeClaim();

        // Price the shares while the claim amount is still excluded from NAV: the
        // depositor buys in at the price prevailing *before* their own assets join the
        // pool, which is what leaves the share price unchanged. Releasing the assets
        // first would price them against an inflated NAV (for a first deposit, an
        // empty pool inflated by the deposit itself).
        shares = super.previewDeposit(assets);

        req.claimableAssets = available - assets;
        totalClaimableDeposits -= assets;

        _mint(receiver, shares);
        _seedHighWaterMark();

        totalDeposited += assets;
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @dev Claims a share-denominated deposit position; the asset cost is priced now.
    function _claimMint(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        _assessFeesBeforeClaim();
        assets = super.previewMint(shares);

        RequestState storage req = _requests[controller];
        uint256 available = req.claimableAssets;
        if (assets > available) revert InsufficientClaimable(controller, assets, available);

        req.claimableAssets = available - assets;
        totalClaimableDeposits -= assets;

        _mint(receiver, shares);
        _seedHighWaterMark();

        totalDeposited += assets;
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @dev Pays a claimable redemption. Shares were burned at request time, so this is a
    ///      pure asset movement bounded by the amount snapshotted then.
    function _claimWithdraw(uint256 assets, address receiver, address controller) internal returns (uint256 shares) {
        RequestState storage req = _requests[controller];
        uint256 availableAssets = req.claimableRedeemAssets;
        if (assets == 0 || assets > availableAssets) {
            revert InsufficientClaimable(controller, assets, availableAssets);
        }

        uint256 availableShares = req.claimableShares;
        shares = assets == availableAssets
            ? availableShares
            : Math.mulDiv(assets, availableShares, availableAssets, Math.Rounding.Ceil);

        req.claimableRedeemAssets = availableAssets - assets;
        req.claimableShares = availableShares - shares;
        totalClaimableRedeemAssets -= assets;

        _ensureLiquidity(assets);
        depositAsset.safeTransfer(receiver, assets);
        totalWithdrawn += assets;

        emit Withdraw(controller, receiver, controller, assets, shares);
    }

    /// @dev Pays a claimable redemption by share count. The payout is fixed at request time,
    ///      so this is not the live `convertToAssets`.
    function _claimRedeem(uint256 shares, address receiver, address controller) internal returns (uint256 assets) {
        RequestState storage req = _requests[controller];
        uint256 availableShares = req.claimableShares;
        if (shares == 0 || shares > availableShares) {
            revert InsufficientClaimable(controller, shares, availableShares);
        }

        uint256 availableAssets = req.claimableRedeemAssets;
        assets = shares == availableShares ? availableAssets : Math.mulDiv(shares, availableAssets, availableShares);

        req.claimableShares = availableShares - shares;
        req.claimableRedeemAssets = availableAssets - assets;
        totalClaimableRedeemAssets -= assets;

        _ensureLiquidity(assets);
        depositAsset.safeTransfer(receiver, assets);
        totalWithdrawn += assets;

        emit Withdraw(controller, receiver, controller, assets, shares);
    }
}
