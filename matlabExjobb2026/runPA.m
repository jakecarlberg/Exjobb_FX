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
runSensitivityNoDiscount = true;

clear settings;
settings.dataFolder    = 'simulatedData';
settings.bomPricing    = 'DeterministicCashFlows';
settings.curFunctional = 'EUR';
settings.startDate     = datenum(2007,1,1);    % Change to 2005 when FX data is available
settings.endDate       = datenum(2024,12,31);  % Change to 2025 when FX data is available
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

fprintf('\n=== Method 1: FX Impacts per Quarter (SEK) ===\n');
fprintf('%-12s %14s %14s\n', 'Period end', 'TI', 'OCI');
fprintf('%s\n', repmat('-', 1, 42));
for p = 1:length(m1.periodEndDates)
  if m1.TI(p) == 0 && m1.OCI(p) == 0, continue; end
  fprintf('%-12s %14s %14s\n', datestr(m1.periodEndDates(p), 'yyyy-mm-dd'), ...
    fmtNum(m1.TI(p)), fmtNum(m1.OCI(p)));
end
fprintf('%s\n', repmat('-', 1, 42));
fprintf('%-12s %14s %14s\n', 'TOTAL', fmtNum(sum(m1.TI)), fmtNum(sum(m1.OCI)));

m2 = computeMethod2(dm, dc, '', bs, pnl);

fprintf('\n=== Method 2: FX Impacts per Quarter (SEK) — all 3 averaging windows ===\n');
fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', 'Period end', ...
  'TI (weekly)', 'OCI (weekly)', 'TI (monthly)', 'OCI (monthly)', ...
  'TI (quarterly)', 'OCI (quarterly)');
fprintf('%s\n', repmat('-', 1, 102));
for p = 1:length(m2.periodEndDates)
  haveAny = m2.weekly.TI(p) ~= 0 || m2.weekly.OCI(p) ~= 0 || ...
            m2.monthly.TI(p) ~= 0 || m2.monthly.OCI(p) ~= 0 || ...
            m2.quarterly.TI(p) ~= 0 || m2.quarterly.OCI(p) ~= 0;
  if ~haveAny, continue; end
  fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', ...
    datestr(m2.periodEndDates(p), 'yyyy-mm-dd'), ...
    fmtNum(m2.weekly.TI(p)),    fmtNum(m2.weekly.OCI(p)), ...
    fmtNum(m2.monthly.TI(p)),   fmtNum(m2.monthly.OCI(p)), ...
    fmtNum(m2.quarterly.TI(p)), fmtNum(m2.quarterly.OCI(p)));
end
fprintf('%s\n', repmat('-', 1, 102));
fprintf('%-12s %14s %14s %14s %14s %14s %14s\n', 'TOTAL', ...
  fmtNum(sum(m2.weekly.TI)),    fmtNum(sum(m2.weekly.OCI)), ...
  fmtNum(sum(m2.monthly.TI)),   fmtNum(sum(m2.monthly.OCI)), ...
  fmtNum(sum(m2.quarterly.TI)), fmtNum(sum(m2.quarterly.OCI)));

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

% --- Panel 3: Constant Currency (PAM only — CY and LY rates) ---
subplot(2,2,3); hold on;
plot(qDates, cumsum(dr.FX_cc_total_quarterly(:))/1e6,    'LineWidth', 1.5);
plot(qDates, cumsum(dr.FX_cc_LY_total_quarterly(:))/1e6, 'LineWidth', 1.5);
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Constant-Currency FX (cumulative, PAM)');
legend('CC — current yr rates', 'CC — last yr rates', 'Location', 'best');

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

% --- Panel 3: Constant Currency (PAM only — CY and LY rates, non-cumulative) ---
subplot(2,2,3); hold on;
plot(qDates, dr.FX_cc_total_quarterly(:)/1e6,    '-', 'LineWidth', 1.5, 'Marker', 'none');
plot(qDates, dr.FX_cc_LY_total_quarterly(:)/1e6, '-', 'LineWidth', 1.5, 'Marker', 'none');
datetick('x', 'yyyy', 'keepticks'); grid on;
ylabel('SEK (millions)'); title('Constant-Currency FX (non-cumulative, PAM)');
legend('CC — current yr rates', 'CC — last yr rates', 'Location', 'best');

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
  fprintf('  Manufactured product order dates (first 5):\n');
  for ii = 1:min(5, length(mfgNonzero))
    k = find(dc.assets.indManufactured == mfgNonzero(ii));
    fprintf('    product %d: orderDate=%s, h0=%.0f, value=%.0f EUR\n', ...
      k, datestr(dc.productOrderDate(k)), dp.hI0(mfgNonzero(ii)), ...
      dp.hI0(mfgNonzero(ii)) * dp.Pbar(1,mfgNonzero(ii)) * dm.fx{dp.IC(mfgNonzero(ii)), iEUR_diag}(1));
  end
end

runExcelExport;
