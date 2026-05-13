% runPA  Single-run Performance Attribution for the thesis simulation.
%
% Loads market data (once), generates a simulated transaction dataset,
% runs the full PA pipeline, prints PAM FX benchmarks and FX gains.

% =========================================================================
% SENSITIVITY TOGGLE
%   true  → runs a second PAM pass with all discount factors set to 1
%            (zero-coupon bonds valued at face value instead of PV).
%            Adds Figure 12 and the Sensitivity_NoDiscount Excel sheet.
%   false → skip (saves ~30 % of total compute time)
% =========================================================================
runSensitivityNoDiscount = false;

clear settings;
settings.dataFolder    = 'simulatedData';
settings.bomPricing    = 'DeterministicCashFlows';
settings.curFunctional = 'EUR';
settings.startDate     = datenum(2007,1,1);
settings.endDate       = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
% Sales: USD AUD CAD GBP ZAR INR CNY
% Procurement: USD EUR CNY GBP
% Functional/Presentation: EUR SEK
% INR dropped due to limited yield curve history (starts Nov 2010)
settings.currencies = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

marketDataSet = 'reutersZero';

if ~exist('dm', 'var') || ~isfield(dm, 'cName') || ~isfield(dm, 'dates')
  [dm] = createDataMarket(marketDataSet, settings);
end

createMatFilesSim(dm, 1, true);

[dc] = createDataCompany(dm, settings);
[dp] = buildPA(dm, dc);
[dr] = performanceAttribution(dm, dc, dp);

% -------------------------------------------------------------------------
% Method 1 & 2 — shared accounting core then each method
% -------------------------------------------------------------------------
addpath(fullfile('IndustryMethods'));
addpath(fullfile('IndustryMethods','Method1'));
addpath(fullfile('IndustryMethods','Method2'));

bs  = buildBalanceSheet(dm, dc);
pnl = buildFunctionalPnL(dm, dc, bs);

m1 = computeMethod1(dm, dc, '', bs, pnl);

m2 = computeMethod2(dm, dc, '', bs, pnl);

% Flow-restricted PAM CC — same flow universe as industry CC, but with the
% three-way (trans / transl / cross) decomposition applied per recognition
% event. Used below as an apples-to-apples benchmark that isolates the
% stock-vs-flow base axis from all other PAM-vs-industry differences.
fcc = performanceAttributionFlowCC(dm, dc, pnl, 'month');

fprintf('\n=== Method 1 & 2 (monthly): FX Impacts per Quarter (SEK) ===\n');
fprintf('%-12s %14s %14s %14s %14s\n', 'Period end', 'M1 TI', 'M1 OCI', 'M2 TI', 'M2 OCI');
fprintf('%s\n', repmat('-', 1, 70));
for p = 1:length(m1.periodEndDates)
  if m1.TI(p) == 0 && m1.OCI(p) == 0, continue; end
  fprintf('%-12s %14s %14s %14s %14s\n', datestr(m1.periodEndDates(p), 'yyyy-mm-dd'), ...
    fmtNum(m1.TI(p)), fmtNum(m1.OCI(p)), ...
    fmtNum(m2.monthly.TI(p)), fmtNum(m2.monthly.OCI(p)));
end
fprintf('%s\n', repmat('-', 1, 70));
fprintf('%-12s %14s %14s %14s %14s\n', 'TOTAL', ...
  fmtNum(sum(m1.TI)), fmtNum(sum(m1.OCI)), ...
  fmtNum(sum(m2.monthly.TI)), fmtNum(sum(m2.monthly.OCI)));

% -------------------------------------------------------------------------
% Quarterly comparison: PAM vs Method 1 vs Method 2
% -------------------------------------------------------------------------

% Aggregate PAM daily contributions into quarters using m1 quarter boundaries
Q          = length(m1.periodEndDates);
PAM_TI_q   = zeros(Q, 1);
PAM_OCI_q  = zeros(Q, 1);
qStartIdx  = m1.bs.dates * 0;   % placeholder — use pnl quarter indices from m1
qSIdx      = m1.pnl.quarterStartIdx;
qEIdx      = m1.pnl.quarterEndIdx;
for q = 1:Q
  rng = qSIdx(q):qEIdx(q);
  PAM_TI_q(q)  = sum(dr.dFX_trans(rng));
  PAM_OCI_q(q) = sum(dr.dFX_transl(rng));
end

% (Quarterly comparison table suppressed — see Excel output for full detail)

% -------------------------------------------------------------------------
% Cross-method comparison (cumulative totals)
% -------------------------------------------------------------------------
fprintf('\n=== Cross-method comparison (cumulative SEK) ===\n');
fprintf('%-20s %18s %18s\n', 'Method', 'TI', 'OCI');
fprintf('%s\n', repmat('-', 1, 58));
fprintf('%-20s %18s %18s\n', 'PAM (benchmark)',      fmtNum(sum(PAM_TI_q)),         fmtNum(sum(PAM_OCI_q)));
fprintf('%-20s %18s %18s\n', 'Method 1 (daily)',     fmtNum(sum(m1.TI)),            fmtNum(sum(m1.OCI)));
fprintf('%-20s %18s %18s\n', 'Method 2 weekly',      fmtNum(sum(m2.weekly.TI)),     fmtNum(sum(m2.weekly.OCI)));
fprintf('%-20s %18s %18s\n', 'Method 2 monthly',     fmtNum(sum(m2.monthly.TI)),    fmtNum(sum(m2.monthly.OCI)));
fprintf('%-20s %18s %18s\n', 'Method 2 quarterly',   fmtNum(sum(m2.quarterly.TI)),  fmtNum(sum(m2.quarterly.OCI)));

fprintf('\nFinal portfolio value (SEK): %s\n', fmtNum(dr.V(end), 4));

% -------------------------------------------------------------------------
% Constant-currency comparison (cumulative totals, method-independent)
% -------------------------------------------------------------------------
fprintf('\n=== Constant-Currency FX Impact (cumulative SEK) ===\n');
fprintf('%-22s %18s %18s\n', 'Variant', 'CC^trans (TI)', 'CC^transl (OCI)');
fprintf('%s\n', repmat('-', 1, 60));
fprintf('%-22s %18s %18s\n', 'M1 (daily vs LY avg)', ...
  fmtNum(sum(m1.cc.M1.quarterly_TI)),    fmtNum(sum(m1.cc.M1.quarterly_OCI)));
fprintf('%-22s %18s %18s\n', 'Average-rate', ...
  fmtNum(sum(m1.cc.avg.quarterly_TI)),   fmtNum(sum(m1.cc.avg.quarterly_OCI)));
fprintf('%-22s %18s %18s\n', 'Closing-rate', ...
  fmtNum(sum(m1.cc.close.quarterly_TI)), fmtNum(sum(m1.cc.close.quarterly_OCI)));
fprintf('%s\n', repmat('-', 1, 60));

% -------------------------------------------------------------------------
% Flow-restricted PAM CC — three lifecycle variants (snap / bonds / BOM)
%   snap   = recognition-day snapshot only
%   bonds  = recognition-to-payment lifecycle (PAM daily integration)
%   BOM    = order-to-payment lifecycle (BOM-extended; full exposure window)
%
% Algebraic identity: bonds.cumulative == BOM.cumulative
%   (only the time distribution differs; BOM puts more contribution in the
%    pre-recognition period)
% -------------------------------------------------------------------------
fprintf('\n=== Flow-restricted PAM CC (3 variants over AR/AP code-10, cumulative SEK) ===\n');
fprintf('%-22s %16s %16s %16s %16s\n', 'Variant', 'trans', 'transl', 'cross', 'total');
fprintf('%s\n', repmat('-', 1, 90));
fprintf('%-22s %16s %16s %16s %16s\n', 'snap   (rec-day)', ...
  fmtNum(sum(fcc.snap.trans_quarterly)),   fmtNum(sum(fcc.snap.transl_quarterly)), ...
  fmtNum(sum(fcc.snap.cross_quarterly)),   fmtNum(sum(fcc.snap.total_quarterly)));
fprintf('%-22s %16s %16s %16s %16s\n', 'bonds  (rec->pay)', ...
  fmtNum(sum(fcc.bonds.trans_quarterly)),  fmtNum(sum(fcc.bonds.transl_quarterly)), ...
  fmtNum(sum(fcc.bonds.cross_quarterly)),  fmtNum(sum(fcc.bonds.total_quarterly)));
fprintf('%-22s %16s %16s %16s %16s\n', 'BOM    (order->pay)', ...
  fmtNum(sum(fcc.BOM.trans_quarterly)),    fmtNum(sum(fcc.BOM.transl_quarterly)), ...
  fmtNum(sum(fcc.BOM.cross_quarterly)),    fmtNum(sum(fcc.BOM.total_quarterly)));
fprintf('%s\n', repmat('-', 1, 90));
fprintf('  Identity check: |bonds.total - BOM.total| = %s SEK (must be ~0)\n', ...
  fmtNum(abs(sum(fcc.bonds.total_quarterly) - sum(fcc.BOM.total_quarterly))));

% =========================================================================
% 2x2 COMPARISON PLOT — PAM vs Method 1 vs Method 2 (monthly)
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;
qDates      = periodDates(2:end);

% Aggregate PAM daily series to quarters
PAM_TI_q     = zeros(nPeriods, 1);
PAM_TI_BOM_q = zeros(nPeriods, 1);
PAM_OCI_q    = zeros(nPeriods, 1);
for p = 1:nPeriods
  idx = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
  if ~isempty(idx)
    PAM_TI_q(p)     = sum(dr.dFX_trans(idx));
    PAM_TI_BOM_q(p) = sum(dr.dFX_trans_BOM(idx));
    PAM_OCI_q(p)    = sum(dr.dFX_transl(idx));
  end
end

% EUR/SEK spot rate
iEUR = find(strcmp(dm.cName, 'EUR'));
iSEK = find(strcmp(dm.cName, 'SEK'));
eurSEK = dm.fx{iEUR, iSEK};

figure(10); clf;

% --- Panel 1: Transaction Impact ---
subplot(2,2,1); hold on;
plot(qDates, cumsum(PAM_TI_q)/1e6,     'LineWidth', 1.5);
plot(qDates, cumsum(PAM_TI_BOM_q)/1e6, 'LineWidth', 1.5);
plot(m1.periodEndDates, cumsum(m1.TI)/1e6,         'LineWidth', 1.5);
plot(m2.periodEndDates, cumsum(m2.monthly.TI)/1e6, 'LineWidth', 1.5);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Transaction Impact (cumulative)');
legend('PAM — Bonds (Eq.4.45)', 'PAM — Bonds+BOM', 'Method 1', 'Method 2 (monthly)', 'Location', 'best');

% --- Panel 2: Translation / OCI ---
subplot(2,2,2); hold on;
plot(qDates, cumsum(PAM_OCI_q)/1e6,                 'LineWidth', 1.5);
plot(m1.periodEndDates, cumsum(m1.OCI)/1e6,         'LineWidth', 1.5);
plot(m2.periodEndDates, cumsum(m2.monthly.OCI)/1e6, 'LineWidth', 1.5);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Translation Impact / OCI (cumulative)');
legend('PAM (Eq.4.46)', 'Method 1', 'Method 2 (monthly)', 'Location', 'best');

% --- Panel 3: Constant-Currency — PAM-flow BOM vs Industry methods (cumulative) ---
% Cumulative version of figure 11 panel 3: full-exposure PAM-flow CC
% (order->payment lifecycle) against the three industry CC variants.
subplot(2,2,3); hold on;
plot(fcc.periodEndDates,   cumsum(fcc.BOM.total_quarterly)/1e6,                                  'LineWidth', 1.5);
plot(m1.cc.periodEndDates, cumsum(m1.cc.M1.quarterly_TI    + m1.cc.M1.quarterly_OCI)/1e6,        'LineWidth', 1.5);
plot(m1.cc.periodEndDates, cumsum(m1.cc.avg.quarterly_TI   + m1.cc.avg.quarterly_OCI)/1e6,       'LineWidth', 1.5);
plot(m1.cc.periodEndDates, cumsum(m1.cc.close.quarterly_TI + m1.cc.close.quarterly_OCI)/1e6,     'LineWidth', 1.5);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Constant-Currency — PAM-flow BOM vs Industry (cumulative)');
legend('PAM-flow BOM total', 'Method 1 total', 'Method 2 (avg) total', 'Method 2 (closing) total', 'Location', 'best');

% --- Panel 4: EUR/SEK rate ---
subplot(2,2,4);
plot(dm.dates, eurSEK, 'k-', 'LineWidth', 1.2);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK per EUR'); title('EUR/SEK Exchange Rate');

sgtitle('PAM vs Method 1 vs Method 2 — Cumulative Comparison');

% =========================================================================
% 2x2 NON-CUMULATIVE COMPARISON PLOT — PAM vs Method 1 vs Method 2 (monthly)
% =========================================================================
figure(11); clf;

% --- Panel 1: Transaction Impact (non-cumulative) ---
subplot(2,2,1); hold on;
plot(qDates, PAM_TI_q/1e6,     '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(qDates, PAM_TI_BOM_q/1e6, '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m1.periodEndDates, m1.TI/1e6,         '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m2.periodEndDates, m2.monthly.TI/1e6, '-', 'LineWidth', 1.5, 'Marker', 'none');
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Transaction Impact (non-cumulative)');
legend('PAM — Bonds (Eq.4.45)', 'PAM — Bonds+BOM', 'Method 1', 'Method 2 (monthly)', 'Location', 'best');

% --- Panel 2: Translation / OCI (non-cumulative) ---
subplot(2,2,2); hold on;
plot(qDates, PAM_OCI_q/1e6,                 '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m1.periodEndDates, m1.OCI/1e6,         '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m2.periodEndDates, m2.monthly.OCI/1e6, '-', 'LineWidth', 1.5, 'Marker', 'none');
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Translation Impact / OCI (non-cumulative)');
legend('PAM (Eq.4.46)', 'Method 1', 'Method 2 (monthly)', 'Location', 'best');

% --- Panel 3: Constant-Currency — PAM-flow BOM vs Industry methods (non-cumulative) ---
% Comparing the full-exposure PAM-flow CC (order->payment lifecycle) against
% the three industry CC variants on the same per-quarter SEK axis.
subplot(2,2,3); hold on;
plot(fcc.periodEndDates,   fcc.BOM.total_quarterly/1e6,                                 '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m1.cc.periodEndDates, (m1.cc.M1.quarterly_TI    + m1.cc.M1.quarterly_OCI)/1e6,     '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m1.cc.periodEndDates, (m1.cc.avg.quarterly_TI   + m1.cc.avg.quarterly_OCI)/1e6,    '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(m1.cc.periodEndDates, (m1.cc.close.quarterly_TI + m1.cc.close.quarterly_OCI)/1e6,  '-', 'LineWidth', 1.5, 'Marker', 'none');
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Constant-Currency — PAM-flow BOM vs Industry (non-cumulative)');
legend('PAM-flow BOM total', 'Method 1 total', 'Method 2 (avg) total', 'Method 2 (closing) total', 'Location', 'best');

% --- Panel 4: EUR/SEK rate ---
subplot(2,2,4);
plot(dm.dates, eurSEK, 'k-', 'LineWidth', 1.2);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK per EUR'); title('EUR/SEK Exchange Rate');

sgtitle('PAM vs Method 1 vs Method 2 — Noncumulative Comparison');

% =========================================================================
% SENSITIVITY RUN: No-Discount PAM
%   Replaces dm.d{c} (discount factors) with all-ones so that every
%   zero-coupon bond is valued at face value × FX rate (no PV discounting).
%   This isolates the contribution of PV discounting to the PAM–M1 gap.
% =========================================================================
if runSensitivityNoDiscount
  fprintf('\n=== Sensitivity run: no-discount PAM ===\n');
  fprintf('  Overriding dm.d{c} with ones (d = 1 for all currencies and horizons)...\n');

  % ---- backup & override discount factors ---------------------------------
  d_backup = dm.d;
  nCurAll  = length(dm.cName);
  for c_nd = 1:nCurAll
    dm.d{c_nd} = ones(size(dm.d{c_nd}));
  end

  % ---- re-run PA pipeline -------------------------------------------------
  dp_nd = buildPA(dm, dc);
  dr_nd = performanceAttribution(dm, dc, dp_nd, false);

  % ---- restore original discount factors ----------------------------------
  dm.d = d_backup;
  fprintf('  No-discount run complete.\n');

  % ---- quarterly aggregation (same grid as main run) ----------------------
  PAM_TI_nd_q     = zeros(nPeriods, 1);
  PAM_TI_BOM_nd_q = zeros(nPeriods, 1);
  for p_nd = 1:nPeriods
    idx_nd = find(dm.dates > periodDates(p_nd) & dm.dates <= periodDates(p_nd + 1));
    if ~isempty(idx_nd)
      PAM_TI_nd_q(p_nd)     = sum(dr_nd.dFX_trans(idx_nd));
      PAM_TI_BOM_nd_q(p_nd) = sum(dr_nd.dFX_trans_BOM(idx_nd));
    end
  end

  % =========================================================================
  % Figure 12 — Sensitivity: No-Discount PAM vs Method 1
  %   Shows only Method 1, PAM Bonds (no discount), PAM Bonds+BOM (no discount).
  %   All lines solid — for comparison toggle runSensitivityNoDiscount on/off.
  % =========================================================================
  figure(12); clf;

  colM1     = 'k';                    % black  — Method 1
  colBonds  = [0.85 0.33 0.10];       % red-orange — PAM Bonds no discount
  colBOM    = [0.47 0.67 0.19];       % green      — PAM Bonds+BOM no discount

  % --- Panel 1: Cumulative TI ---
  subplot(2, 1, 1); hold on;
  plot(m1.periodEndDates,      cumsum(m1.TI)        / 1e6, '-', 'Color', colM1,    'LineWidth', 2.0);
  plot(qDates, cumsum(PAM_TI_nd_q)     / 1e6,             '-', 'Color', colBonds,  'LineWidth', 1.5);
  plot(qDates, cumsum(PAM_TI_BOM_nd_q) / 1e6,             '-', 'Color', colBOM,    'LineWidth', 1.5);
  datetick('x', 'yyyy', 'keepticks'); grid on;
  ylabel('SEK (millions)');
  title('Cumulative Transaction Impact');
  legend('Method 1', 'PAM Bonds (no discount)', 'PAM Bonds+BOM (no discount)', ...
         'Location', 'best');

  % --- Panel 2: Quarterly TI (non-cumulative) ---
  subplot(2, 1, 2); hold on;
  plot(m1.periodEndDates,  m1.TI        / 1e6, '-', 'Color', colM1,    'LineWidth', 2.0);
  plot(qDates, PAM_TI_nd_q     / 1e6,          '-', 'Color', colBonds,  'LineWidth', 1.5);
  plot(qDates, PAM_TI_BOM_nd_q / 1e6,          '-', 'Color', colBOM,    'LineWidth', 1.5);
  datetick('x', 'yyyy', 'keepticks'); grid on;
  ylabel('SEK (millions)');
  title('Quarterly Transaction Impact (non-cumulative)');
  legend('Method 1', 'PAM Bonds (no discount)', 'PAM Bonds+BOM (no discount)', ...
         'Location', 'best');

  sgtitle('Figure 12 — Sensitivity: No-Discount PAM vs Method 1');
end

% -------------------------------------------------------------------------
nonzeroIdx = find(dp.hI0 ~= 0);
fprintf('Non-zero initial holdings: %d assets\n', length(nonzeroIdx));
iEUR_diag = find(strcmp(dm.cName,'EUR'));
valEUR = zeros(1, length(nonzeroIdx));
for ii = 1:length(nonzeroIdx)
  j = nonzeroIdx(ii);
  valEUR(ii) = dp.hI0(j) * dp.Pbar(1,j) * dm.fx{dp.IC(j), iEUR_diag}(1);
end
fprintf('Sum of initial holdings value (EUR): %.0f\n', sum(valEUR));
nInv  = sum(ismember(nonzeroIdx, dc.assets.indPriceInventory));
nShr  = sum(ismember(nonzeroIdx, dc.assets.indPriceShrinkage));
nMfg  = sum(ismember(nonzeroIdx, dc.assets.indManufactured));
nBond = sum(ismember(nonzeroIdx, dc.assets.indBond));
fprintf('  Components (inventory): %d,  Shrinkage: %d,  Manufactured: %d,  Bonds: %d\n', nInv, nShr, nMfg, nBond);
mfgNonzero = intersect(nonzeroIdx, dc.assets.indManufactured);
if ~isempty(mfgNonzero)
  fprintf('  Manufactured (Component+Product BOMs) with non-zero h0 (first 5):\n');
  for ii = 1:min(5, length(mfgNonzero))
    gIdx = mfgNonzero(ii);   % global asset index
    % Identify whether this is a Component BOM or Product BOM and look up
    % the corresponding product/PO. With multiple BOMs per product, the
    % type-specific index is no longer 1:1 with product index.
    label = sprintf('asset %d', gIdx);
    if isfield(dc, 'productBomId')
      pIdx = find(arrayfun(@(b) b > 0 && dc.assets.indManufactured(b) == gIdx, dc.productBomId), 1);
      if ~isempty(pIdx)
        label = sprintf('Product BOM (product %d, orderDate=%s)', pIdx, datestr(dc.productOrderDate(pIdx)));
      end
    end
    if ismember('jComponentBOM', dc.b.Properties.VariableNames)
      bRow = find(arrayfun(@(b) b > 0 && dc.assets.indManufactured(b) == gIdx, dc.b.jComponentBOM), 1);
      if ~isempty(bRow)
        label = sprintf('Component BOM (PO %d, comp %d, product %d)', ...
          dc.b.purchaseOrderNumber(bRow), dc.b.componentNumber(bRow), dc.b.product(bRow));
      end
    end
    fprintf('    %s: h0=%.0f, value=%.0f EUR\n', label, dp.hI0(gIdx), ...
      dp.hI0(gIdx) * dp.Pbar(1,gIdx) * dm.fx{dp.IC(gIdx), iEUR_diag}(1));
  end
end

% =========================================================================
% PAM vs Industry CC comparison — three per-quarter figures (one per channel)
%   Figure 13: Trans CC channel
%   Figure 14: Transl CC channel
%   Figure 15: Total CC
% =========================================================================
qDates = dr.periodDates(2:end);     % quarter-end dates
nP     = length(qDates);

% PAM per-quarter series
PAM_trans_q             = dr.FX_cc_trans_quarterly;
PAM_transl_q            = dr.FX_cc_transl_quarterly;
PAM_cross_q             = dr.FX_cc_cross_quarterly;
PAM_total_q             = dr.FX_cc_total_quarterly;
% PAM trans + cross is the natural counterpart to industry trans (industry
% absorbs the cross term inside Δc→SEK in its published transaction component)
PAM_trans_plus_cross_q  = PAM_trans_q + PAM_cross_q;

% Industry quarterly series — align to PAM quarter grid
M1_trans_q     = zeros(nP,1); M1_transl_q     = zeros(nP,1);
Mavg_trans_q   = zeros(nP,1); Mavg_transl_q   = zeros(nP,1);
Mclose_trans_q = zeros(nP,1); Mclose_transl_q = zeros(nP,1);
if isfield(m1, 'cc')
  for p = 1:nP
    [~, mp] = min(abs(m1.cc.periodEndDates - qDates(p)));
    if abs(m1.cc.periodEndDates(mp) - qDates(p)) <= 5
      M1_trans_q(p)     = m1.cc.M1.quarterly_TI(mp);
      M1_transl_q(p)    = m1.cc.M1.quarterly_OCI(mp);
      Mavg_trans_q(p)   = m1.cc.avg.quarterly_TI(mp);
      Mavg_transl_q(p)  = m1.cc.avg.quarterly_OCI(mp);
      Mclose_trans_q(p) = m1.cc.close.quarterly_TI(mp);
      Mclose_transl_q(p)= m1.cc.close.quarterly_OCI(mp);
    end
  end
end
M1_total_q     = M1_trans_q     + M1_transl_q;
Mavg_total_q   = Mavg_trans_q   + Mavg_transl_q;
Mclose_total_q = Mclose_trans_q + Mclose_transl_q;

% --- Flow-restricted PAM CC: project all three modes onto PAM quarter grid -
% Each lifecycle mode gets its own quarter-aligned series:
%   fcc_snap_*_q    — recognition-day snapshot only
%   fcc_bonds_*_q   — recognition-to-payment lifecycle (PAM daily integration)
%   fcc_BOM_*_q     — order-to-payment lifecycle (BOM-extended, full window)
fcc_snap_trans_q   = zeros(nP, 1); fcc_snap_transl_q  = zeros(nP, 1);
fcc_snap_cross_q   = zeros(nP, 1); fcc_snap_total_q   = zeros(nP, 1);
fcc_bonds_trans_q  = zeros(nP, 1); fcc_bonds_transl_q = zeros(nP, 1);
fcc_bonds_cross_q  = zeros(nP, 1); fcc_bonds_total_q  = zeros(nP, 1);
fcc_BOM_trans_q    = zeros(nP, 1); fcc_BOM_transl_q   = zeros(nP, 1);
fcc_BOM_cross_q    = zeros(nP, 1); fcc_BOM_total_q    = zeros(nP, 1);

for p = 1:nP
  [~, mp] = min(abs(fcc.periodEndDates - qDates(p)));
  if abs(fcc.periodEndDates(mp) - qDates(p)) <= 5
    fcc_snap_trans_q(p)   = fcc.snap.trans_quarterly(mp);
    fcc_snap_transl_q(p)  = fcc.snap.transl_quarterly(mp);
    fcc_snap_cross_q(p)   = fcc.snap.cross_quarterly(mp);
    fcc_snap_total_q(p)   = fcc.snap.total_quarterly(mp);

    fcc_bonds_trans_q(p)  = fcc.bonds.trans_quarterly(mp);
    fcc_bonds_transl_q(p) = fcc.bonds.transl_quarterly(mp);
    fcc_bonds_cross_q(p)  = fcc.bonds.cross_quarterly(mp);
    fcc_bonds_total_q(p)  = fcc.bonds.total_quarterly(mp);

    fcc_BOM_trans_q(p)    = fcc.BOM.trans_quarterly(mp);
    fcc_BOM_transl_q(p)   = fcc.BOM.transl_quarterly(mp);
    fcc_BOM_cross_q(p)    = fcc.BOM.cross_quarterly(mp);
    fcc_BOM_total_q(p)    = fcc.BOM.total_quarterly(mp);
  end
end

% Industry-CC^trans counterpart: PAM (trans + cross), per mode
fcc_snap_tr_plus_cr_q  = fcc_snap_trans_q  + fcc_snap_cross_q;
fcc_bonds_tr_plus_cr_q = fcc_bonds_trans_q + fcc_bonds_cross_q;
fcc_BOM_tr_plus_cr_q   = fcc_BOM_trans_q   + fcc_BOM_cross_q;

% =========================================================================
% CC validation diagnostics: per-quarter correlation PAM vs Industry
%   Magnitudes differ by ~10x (gross portfolio vs net flow exposure), but
%   if the methods capture the same FX pattern the correlations should be
%   strongly positive. This isolates "directional agreement" from
%   "magnitude agreement".
% =========================================================================
ccCorrPairs = { ...
  '====================== PAM-STOCK (whole portfolio, daily integration) ======', [], [] ; ...
  'PAM-stock total       vs M1 total           ', PAM_total_q,             M1_total_q     ; ...
  'PAM-stock total       vs M2avg total        ', PAM_total_q,             Mavg_total_q   ; ...
  'PAM-stock total       vs M2close total      ', PAM_total_q,             Mclose_total_q ; ...
  'PAM-stock(tr+cr)      vs M1 trans           ', PAM_trans_plus_cross_q,  M1_trans_q     ; ...
  'PAM-stock(tr+cr)      vs M2avg trans        ', PAM_trans_plus_cross_q,  Mavg_trans_q   ; ...
  'PAM-stock(tr+cr)      vs M2close trans      ', PAM_trans_plus_cross_q,  Mclose_trans_q ; ...
  'PAM-stock transl      vs Industry transl    ', PAM_transl_q,            M1_transl_q    ; ...
  '====================== PAM-FLOW SNAP (recognition-day, mimics industry) ====', [], [] ; ...
  'PAM-flow snap total   vs M1 total           ', fcc_snap_total_q,        M1_total_q     ; ...
  'PAM-flow snap total   vs M2avg total        ', fcc_snap_total_q,        Mavg_total_q   ; ...
  'PAM-flow snap total   vs M2close total      ', fcc_snap_total_q,        Mclose_total_q ; ...
  'PAM-flow snap total   vs M1 trans  (NATURAL)', fcc_snap_total_q,        M1_trans_q     ; ...
  'PAM-flow snap total   vs M2avg trans        ', fcc_snap_total_q,        Mavg_trans_q   ; ...
  'PAM-flow snap total   vs M2close trans      ', fcc_snap_total_q,        Mclose_trans_q ; ...
  'PAM-flow snap(tr+cr)  vs M1 trans           ', fcc_snap_tr_plus_cr_q,   M1_trans_q     ; ...
  '====================== PAM-FLOW BONDS (recognition->payment lifecycle) =====', [], [] ; ...
  'PAM-flow bonds total  vs M1 total           ', fcc_bonds_total_q,       M1_total_q     ; ...
  'PAM-flow bonds total  vs M2avg total        ', fcc_bonds_total_q,       Mavg_total_q   ; ...
  'PAM-flow bonds total  vs M2close total      ', fcc_bonds_total_q,       Mclose_total_q ; ...
  'PAM-flow bonds total  vs M1 trans  (NATURAL)', fcc_bonds_total_q,       M1_trans_q     ; ...
  'PAM-flow bonds total  vs M2avg trans        ', fcc_bonds_total_q,       Mavg_trans_q   ; ...
  'PAM-flow bonds total  vs M2close trans      ', fcc_bonds_total_q,       Mclose_trans_q ; ...
  'PAM-flow bonds(tr+cr) vs M1 trans           ', fcc_bonds_tr_plus_cr_q,  M1_trans_q     ; ...
  '====================== PAM-FLOW BOM (order->payment, full exposure) ========', [], [] ; ...
  'PAM-flow BOM total    vs M1 total           ', fcc_BOM_total_q,         M1_total_q     ; ...
  'PAM-flow BOM total    vs M2avg total        ', fcc_BOM_total_q,         Mavg_total_q   ; ...
  'PAM-flow BOM total    vs M2close total      ', fcc_BOM_total_q,         Mclose_total_q ; ...
  'PAM-flow BOM total    vs M1 trans  (NATURAL)', fcc_BOM_total_q,         M1_trans_q     ; ...
  'PAM-flow BOM total    vs M2avg trans        ', fcc_BOM_total_q,         Mavg_trans_q   ; ...
  'PAM-flow BOM total    vs M2close trans      ', fcc_BOM_total_q,         Mclose_trans_q ; ...
  'PAM-flow BOM(tr+cr)   vs M1 trans           ', fcc_BOM_tr_plus_cr_q,    M1_trans_q     ; ...
  '====================== INTERNAL: PAM variants vs each other ================', [], [] ; ...
  'PAM-stock total       vs PAM-flow snap      ', PAM_total_q,             fcc_snap_total_q  ; ...
  'PAM-stock total       vs PAM-flow bonds     ', PAM_total_q,             fcc_bonds_total_q ; ...
  'PAM-stock total       vs PAM-flow BOM       ', PAM_total_q,             fcc_BOM_total_q   ; ...
  'PAM-flow snap total   vs PAM-flow bonds     ', fcc_snap_total_q,        fcc_bonds_total_q ; ...
  'PAM-flow snap total   vs PAM-flow BOM       ', fcc_snap_total_q,        fcc_BOM_total_q   ; ...
  'PAM-flow bonds total  vs PAM-flow BOM       ', fcc_bonds_total_q,       fcc_BOM_total_q   };

fprintf('\n=== CC per-quarter correlation: PAM vs Industry methods ===\n');
for ccI = 1:size(ccCorrPairs, 1)
  a = ccCorrPairs{ccI, 2};
  b = ccCorrPairs{ccI, 3};
  if isempty(a) || isempty(b)
    % Section separator row
    fprintf('  %s\n', ccCorrPairs{ccI, 1});
    continue;
  end
  a = a(:); b = b(:);
  if std(a) > 0 && std(b) > 0
    % Pearson correlation — base-MATLAB only (no Statistics Toolbox dependency)
    am = a - mean(a);
    bm = b - mean(b);
    rho = sum(am .* bm) / sqrt(sum(am.^2) * sum(bm.^2));
    fprintf('  %s : %6.3f\n', ccCorrPairs{ccI, 1}, rho);
  else
    fprintf('  %s :    NaN  (one series is constant — industry CC unavailable?)\n', ccCorrPairs{ccI, 1});
  end
end
clear ccCorrPairs ccI a b am bm rho

% =========================================================================
% Per-PAM-flow-CC-variant non-cumulative comparison vs industry methods
% (one figure per variant, all on the same per-quarter SEK axis)
%   Fig 13: PAM-flow snap total  vs M1 / M2avg / M2close
%   Fig 14: PAM-flow bonds total vs M1 / M2avg / M2close
%   Fig 15: PAM-flow BOM total   vs M1 / M2avg / M2close
%   Fig 16: PAM-flow snap / bonds / BOM overlay (internal)
% =========================================================================

% --- Figure 13: PAM-flow SNAP (recognition snapshot) vs methods ------------
figure(13); clf;
hold on;
plot(qDates, fcc_snap_total_q, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow snap total');
plot(qDates, M1_total_q,       'LineWidth', 1.4, 'DisplayName', 'M1 total');
plot(qDates, Mavg_total_q,     'LineWidth', 1.4, 'DisplayName', 'M2avg total');
plot(qDates, Mclose_total_q,   'LineWidth', 1.4, 'DisplayName', 'M2close total');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on;
datetick('x', 'yyyy');
xlabel('Quarter end'); ylabel('SEK per quarter');
title('PAM-flow SNAP (recognition-day) vs Industry — per quarter');
legend('Location', 'best');

% --- Figure 14: PAM-flow BONDS (recognition->payment) vs methods -----------
figure(14); clf;
hold on;
plot(qDates, fcc_bonds_total_q, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow bonds total');
plot(qDates, M1_total_q,        'LineWidth', 1.4, 'DisplayName', 'M1 total');
plot(qDates, Mavg_total_q,      'LineWidth', 1.4, 'DisplayName', 'M2avg total');
plot(qDates, Mclose_total_q,    'LineWidth', 1.4, 'DisplayName', 'M2close total');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on;
datetick('x', 'yyyy');
xlabel('Quarter end'); ylabel('SEK per quarter');
title('PAM-flow BONDS (recognition->payment lifecycle) vs Industry — per quarter');
legend('Location', 'best');

% --- Figure 15: PAM-flow BOM (order->payment) vs methods -------------------
figure(15); clf;
hold on;
plot(qDates, fcc_BOM_total_q, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow BOM total');
plot(qDates, M1_total_q,      'LineWidth', 1.4, 'DisplayName', 'M1 total');
plot(qDates, Mavg_total_q,    'LineWidth', 1.4, 'DisplayName', 'M2avg total');
plot(qDates, Mclose_total_q,  'LineWidth', 1.4, 'DisplayName', 'M2close total');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on;
datetick('x', 'yyyy');
xlabel('Quarter end'); ylabel('SEK per quarter');
title('PAM-flow BOM (order->payment, full exposure) vs Industry — per quarter');
legend('Location', 'best');

% --- Figure 16: All three PAM-flow variants overlay (no methods) -----------
%   Useful diagnostic for seeing how the lifecycle window affects the
%   per-quarter time distribution. Cumulative totals of bonds and BOM are
%   identical by construction; only the time profile differs.
figure(16); clf;
hold on;
plot(qDates, fcc_snap_total_q,  'LineWidth', 1.8, 'DisplayName', 'snap   (recognition-day)');
plot(qDates, fcc_bonds_total_q, 'LineWidth', 1.6, 'DisplayName', 'bonds  (recognition->payment)');
plot(qDates, fcc_BOM_total_q,   'LineWidth', 1.4, 'DisplayName', 'BOM    (order->payment)');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on;
datetick('x', 'yyyy');
xlabel('Quarter end'); ylabel('SEK per quarter');
title('PAM-flow CC: snap vs bonds vs BOM — per-quarter time distribution');
legend('Location', 'best');

% =========================================================================
% Figure 17: Trans component — every PAM vs every industry method
%   2x2 grid, one panel per PAM variant. Each panel plots the PAM's
%   industry-counterpart (PAM trans+cross, since industry CC^trans absorbs
%   the cross term inside delta-c->SEK) against M1 / M2avg / M2close trans.
%   All panels share the same per-quarter SEK axis.
% =========================================================================
figure(17); clf;

% --- Panel 1: PAM-stock ---
subplot(2,2,1); hold on;
plot(qDates, PAM_trans_plus_cross_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-stock (trans+cross)');
plot(qDates, M1_trans_q/1e6,             'LineWidth', 1.4, 'DisplayName', 'M1 trans');
plot(qDates, Mavg_trans_q/1e6,           'LineWidth', 1.4, 'DisplayName', 'M2avg trans');
plot(qDates, Mclose_trans_q/1e6,         'LineWidth', 1.4, 'DisplayName', 'M2close trans');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-stock vs Industry');
legend('Location', 'best');

% --- Panel 2: PAM-flow snap ---
subplot(2,2,2); hold on;
plot(qDates, fcc_snap_tr_plus_cr_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow snap (trans+cross)');
plot(qDates, M1_trans_q/1e6,            'LineWidth', 1.4, 'DisplayName', 'M1 trans');
plot(qDates, Mavg_trans_q/1e6,          'LineWidth', 1.4, 'DisplayName', 'M2avg trans');
plot(qDates, Mclose_trans_q/1e6,        'LineWidth', 1.4, 'DisplayName', 'M2close trans');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow snap vs Industry');
legend('Location', 'best');

% --- Panel 3: PAM-flow bonds ---
subplot(2,2,3); hold on;
plot(qDates, fcc_bonds_tr_plus_cr_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow bonds (trans+cross)');
plot(qDates, M1_trans_q/1e6,             'LineWidth', 1.4, 'DisplayName', 'M1 trans');
plot(qDates, Mavg_trans_q/1e6,           'LineWidth', 1.4, 'DisplayName', 'M2avg trans');
plot(qDates, Mclose_trans_q/1e6,         'LineWidth', 1.4, 'DisplayName', 'M2close trans');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow bonds vs Industry');
legend('Location', 'best');

% --- Panel 4: PAM-flow BOM ---
subplot(2,2,4); hold on;
plot(qDates, fcc_BOM_tr_plus_cr_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow BOM (trans+cross)');
plot(qDates, M1_trans_q/1e6,           'LineWidth', 1.4, 'DisplayName', 'M1 trans');
plot(qDates, Mavg_trans_q/1e6,         'LineWidth', 1.4, 'DisplayName', 'M2avg trans');
plot(qDates, Mclose_trans_q/1e6,       'LineWidth', 1.4, 'DisplayName', 'M2close trans');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow BOM vs Industry');
legend('Location', 'best');

sgtitle('CC^{trans} component — PAM variants vs Industry methods (per quarter)');

% =========================================================================
% Figure 18: Transl component — every PAM vs Industry transl
%   2x2 grid, one panel per PAM variant. Industry CC^transl is identical
%   across M1 / M2avg / M2close (all use NI x delta(EUR/SEK avg) — same
%   formula); they're plotted as three separate lines for completeness, but
%   they overlap exactly in the simulation.
%   PAM transl differs across variants because the underlying base differs:
%     PAM-stock transl   = (whole portfolio)        x delta(EUR/SEK)
%     PAM-flow snap      = (flows at recognition)   x delta(EUR/SEK)  (per event, fixed PY)
%     PAM-flow bonds     = (flows over rec->pay)    integrated daily
%     PAM-flow BOM       = (flows over order->pay)  integrated daily
% =========================================================================
figure(18); clf;

% --- Panel 1: PAM-stock ---
subplot(2,2,1); hold on;
plot(qDates, PAM_transl_q/1e6,    'LineWidth', 1.8, 'DisplayName', 'PAM-stock transl (portfolio x delta-EUR/SEK)');
plot(qDates, M1_transl_q/1e6,     'LineWidth', 1.4, 'DisplayName', 'M1 transl (NI x delta-EUR/SEK)');
plot(qDates, Mavg_transl_q/1e6,   'LineWidth', 1.4, 'DisplayName', 'M2avg transl (= M1)');
plot(qDates, Mclose_transl_q/1e6, 'LineWidth', 1.4, 'DisplayName', 'M2close transl (= M1)');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-stock vs Industry');
legend('Location', 'best');

% --- Panel 2: PAM-flow snap ---
subplot(2,2,2); hold on;
plot(qDates, fcc_snap_transl_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow snap transl');
plot(qDates, M1_transl_q/1e6,       'LineWidth', 1.4, 'DisplayName', 'M1 transl');
plot(qDates, Mavg_transl_q/1e6,     'LineWidth', 1.4, 'DisplayName', 'M2avg transl (= M1)');
plot(qDates, Mclose_transl_q/1e6,   'LineWidth', 1.4, 'DisplayName', 'M2close transl (= M1)');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow snap vs Industry');
legend('Location', 'best');

% --- Panel 3: PAM-flow bonds ---
subplot(2,2,3); hold on;
plot(qDates, fcc_bonds_transl_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow bonds transl');
plot(qDates, M1_transl_q/1e6,        'LineWidth', 1.4, 'DisplayName', 'M1 transl');
plot(qDates, Mavg_transl_q/1e6,      'LineWidth', 1.4, 'DisplayName', 'M2avg transl (= M1)');
plot(qDates, Mclose_transl_q/1e6,    'LineWidth', 1.4, 'DisplayName', 'M2close transl (= M1)');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow bonds vs Industry');
legend('Location', 'best');

% --- Panel 4: PAM-flow BOM ---
subplot(2,2,4); hold on;
plot(qDates, fcc_BOM_transl_q/1e6, 'LineWidth', 1.8, 'DisplayName', 'PAM-flow BOM transl');
plot(qDates, M1_transl_q/1e6,      'LineWidth', 1.4, 'DisplayName', 'M1 transl');
plot(qDates, Mavg_transl_q/1e6,    'LineWidth', 1.4, 'DisplayName', 'M2avg transl (= M1)');
plot(qDates, Mclose_transl_q/1e6,  'LineWidth', 1.4, 'DisplayName', 'M2close transl (= M1)');
yline(0, ':k', 'HandleVisibility', 'off');
hold off; grid on; datetick('x', 'yyyy', 'keepticks');
ylabel('SEK (millions)'); title('PAM-flow BOM vs Industry');
legend('Location', 'best');

sgtitle('CC^{transl} component — PAM variants vs Industry methods (per quarter)');

runExcelExport;
