% runMC  Monte Carlo driver — PAM + Method 1 + Method 2 FX benchmark analysis
%
% Runs K iterations of the full pipeline:
%   createMatFilesSim -> createDataCompany -> buildPA -> performanceAttribution
%                                          -> buildBalanceSheet/buildFunctionalPnL
%                                          -> computeMethod1 / computeMethod2
%
% Market data (dm) is loaded once and kept fixed across all iterations,
% consistent with the thesis (Section 4.2.1): stochastic transaction
% datasets, fixed historical exchange rate series 2005-2025.
%
% bs and pnl (shared accounting core) are computed once per iteration and
% passed to both computeMethod1 and computeMethod2 — no redundant work.
%
% Results are stored per quarter [K x nPeriods] for all methods.
%
% Usage:
%   runMC              % default K=100
%   K = 500; runMC     % override before running

% =========================================================================
% SETTINGS
% =========================================================================
if ~exist('K',    'var'), K    = 10; end

settings.dataFolder         = 'simulatedData';
settings.bomPricing         = 'DeterministicCashFlows';
settings.curFunctional      = 'EUR';
settings.startDate          = datenum(2007,1,1);  % Change to 2005 when FX data is available
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
% INR dropped due to limited yield curve history (starts Nov 2010)
settings.currencies         = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

marketDataSet = 'reutersZero';

% =========================================================================
% PATHS  (industry methods shared core + Method 1 + Method 2)
% =========================================================================
addpath(fullfile('IndustryMethods'));
addpath(fullfile('IndustryMethods', 'Method1'));
addpath(fullfile('IndustryMethods', 'Method2'));

% =========================================================================
% LOAD MARKET DATA ONCE  (fixed across MC iterations)
% =========================================================================
if ~exist('dm', 'var') || ~isfield(dm, 'cName') || ~isfield(dm, 'dates')
  fprintf('Loading market data...\n');
  dm = createDataMarket(marketDataSet, settings);
  fprintf('Market data loaded: %d dates, %d currencies\n\n', ...
    length(dm.dates), length(dm.cName));
end

% =========================================================================
% QUARTERLY PERIOD BOUNDARIES  (shared with computeFXGains)
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;

% Pre-compute which dm date indices belong to each quarter
quarterIdx = cell(nPeriods, 1);
for p = 1:nPeriods
  quarterIdx{p} = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
end

% =========================================================================
% PRE-ALLOCATE RESULT ARRAYS  [K x nPeriods]
% =========================================================================

% --- PAM benchmarks -------------------------------------------------------
mc.FX_trans     = nan(K, nPeriods);   % Transactional FX — Bonds only (Eq. 4.45)
mc.FX_trans_BOM = nan(K, nPeriods);   % Transactional FX — Bonds + BOM
mc.FX_transl    = nan(K, nPeriods);   % Translation FX per quarter   (Eq. 4.46)
mc.FX_cc        = nan(K, nPeriods);   % Constant-currency per quarter (Eq. 4.47)
mc.FX_trans_CC  = nan(K, nPeriods);   % CC transaction component
mc.FX_transl_CC = nan(K, nPeriods);   % CC translation component
mc.FX_cc_total  = nan(K, nPeriods);   % CC total (trans + transl)
mc.FX_trans_CC_LY  = nan(K, nPeriods);
mc.FX_transl_CC_LY = nan(K, nPeriods);
mc.FX_cc_LY_total  = nan(K, nPeriods);

% --- Method 1 (actual daily rate) ----------------------------------------
mc.M1_TI  = nan(K, nPeriods);   % Transactional Impact (Eq. 4.21)
mc.M1_OCI = nan(K, nPeriods);   % Translation Impact / OCI (Eq. 4.22-4.25)

% --- Method 2 (sub-period average rate, 3 variants) ----------------------
mc.M2w_TI  = nan(K, nPeriods);  % weekly avg — TI
mc.M2w_OCI = nan(K, nPeriods);  % weekly avg — OCI
mc.M2m_TI  = nan(K, nPeriods);  % monthly avg — TI
mc.M2m_OCI = nan(K, nPeriods);  % monthly avg — OCI
mc.M2q_TI  = nan(K, nPeriods);  % quarterly avg — TI
mc.M2q_OCI = nan(K, nPeriods);  % quarterly avg — OCI

% --- Constant-currency (CC) impacts [K x nPeriods] -----------------------
% M1 variant: actual delivery-date rate vs prior-yr monthly avg
mc.M1_CC_TI     = nan(K, nPeriods);
mc.M1_CC_OCI    = nan(K, nPeriods);
% avg variant: monthly avg rate current vs prior year
mc.CC_avg_TI    = nan(K, nPeriods);
mc.CC_avg_OCI   = nan(K, nPeriods);
% close variant: period-opening closing rate current vs prior year
mc.CC_close_TI  = nan(K, nPeriods);
mc.CC_close_OCI = nan(K, nPeriods);

mc.seeds       = (1:K)';
mc.periodDates = periodDates;

% =========================================================================
% MONTE CARLO LOOP
% =========================================================================
fprintf('Starting Monte Carlo: K=%d, nQuarters=%d\n\n', K, nPeriods);
tStart = tic;

for k = 1:K

  createMatFilesSim(dm, k, false);

  try
    dc = createDataCompany(dm, settings);

    % --- PAM --------------------------------------------------------------
    dp = buildPA(dm, dc);
    dr = performanceAttribution(dm, dc, dp, false);

    for p = 1:nPeriods
      idx = quarterIdx{p};
      if ~isempty(idx)
        mc.FX_trans(k,     p) = sum(dr.dFX_trans(idx));
        mc.FX_trans_BOM(k, p) = sum(dr.dFX_trans_BOM(idx));
        mc.FX_transl(k,    p) = sum(dr.dFX_transl(idx));
        mc.FX_cc(k,        p) = sum(dr.dFX_cc(idx));
      end
    end
    mc.FX_trans_CC(k,  :) = dr.FX_trans_CC_quarterly(:)';
    mc.FX_transl_CC(k, :) = dr.FX_transl_CC_quarterly(:)';
    mc.FX_cc_total(k,  :) = dr.FX_cc_total_quarterly(:)';
    mc.FX_trans_CC_LY(k,  :) = dr.FX_trans_CC_LY_quarterly(:)';
    mc.FX_transl_CC_LY(k, :) = dr.FX_transl_CC_LY_quarterly(:)';
    mc.FX_cc_LY_total(k,  :) = dr.FX_cc_LY_total_quarterly(:)';

    % --- Shared accounting core (once per iteration) ----------------------
    bs  = buildBalanceSheet(dm, dc);
    pnl = buildFunctionalPnL(dm, dc, bs);

    % --- Method 1 ---------------------------------------------------------
    m1 = computeMethod1(dm, dc, '', bs, pnl);
    mc.M1_TI(k,  :) = m1.TI(:)';
    mc.M1_OCI(k, :) = m1.OCI(:)';

    % --- Method 2 ---------------------------------------------------------
    m2 = computeMethod2(dm, dc, '', bs, pnl);
    mc.M2w_TI(k,  :) = m2.weekly.TI(:)';
    mc.M2w_OCI(k, :) = m2.weekly.OCI(:)';
    mc.M2m_TI(k,  :) = m2.monthly.TI(:)';
    mc.M2m_OCI(k, :) = m2.monthly.OCI(:)';
    mc.M2q_TI(k,  :) = m2.quarterly.TI(:)';
    mc.M2q_OCI(k, :) = m2.quarterly.OCI(:)';

    % --- Constant-currency (three variants) ---------------------------------
    P = min(length(m1.cc.avg.quarterly_TI), nPeriods);
    mc.M1_CC_TI(k,    1:P) = m1.cc.M1.quarterly_TI(1:P)';
    mc.M1_CC_OCI(k,   1:P) = m1.cc.M1.quarterly_OCI(1:P)';
    mc.CC_avg_TI(k,   1:P) = m1.cc.avg.quarterly_TI(1:P)';
    mc.CC_avg_OCI(k,  1:P) = m1.cc.avg.quarterly_OCI(1:P)';
    mc.CC_close_TI(k, 1:P) = m1.cc.close.quarterly_TI(1:P)';
    mc.CC_close_OCI(k,1:P) = m1.cc.close.quarterly_OCI(1:P)';

  catch ME
    fprintf('  [iter %d] ERROR: %s\n', k, ME.message);
  end

  if mod(k, max(1, round(K/10))) == 0
    elapsed = toc(tStart);
    eta     = elapsed / k * (K - k);
    fprintf('  %4d / %4d  (%.0fs elapsed, ~%.0fs remaining)\n', k, K, elapsed, eta);
  end

end

fprintf('\nMonte Carlo complete. Total time: %.1fs\n', toc(tStart));

% =========================================================================
% SUMMARY STATISTICS  (across iterations, per quarter)
% =========================================================================
valid = ~any(isnan(mc.FX_trans),     2) & ...
        ~any(isnan(mc.FX_trans_BOM), 2) & ...
        ~any(isnan(mc.FX_cc_total),  2) & ...
        ~any(isnan(mc.FX_cc_LY_total), 2) & ...
        ~any(isnan(mc.M1_TI),  2) & ...
        ~any(isnan(mc.M2m_TI), 2);
nValid = sum(valid);

fprintf('\n=== PAM FX Benchmarks: mean per quarter across %d iterations (SEK) ===\n', nValid);
fprintf('%-12s %14s %14s %14s\n', 'Quarter end', 'Transactional', 'Translation', 'Const-cur');
fprintf('%s\n', repmat('-', 1, 58));
for p = 1:nPeriods
  fprintf('%-12s %14.0f %14.0f %14.0f\n', ...
    datestr(periodDates(p+1), 'yyyy-mm-dd'), ...
    mean(mc.FX_trans(valid, p)), ...
    mean(mc.FX_transl(valid, p)), ...
    mean(mc.FX_cc(valid, p)));
end

fprintf('\n=== Full-period totals (sum of quarters) ===\n');
names  = {'Trans — Bonds only (Eq.4.45)', 'Trans — Bonds+BOM      ', 'Translation   (Eq.4.46)', 'Const-currency(Eq.4.47)'};
fields = {'FX_trans', 'FX_trans_BOM', 'FX_transl', 'FX_cc'};
fprintf('%-28s %12s %12s %12s %12s %12s\n', '', 'Mean', 'Std', 'P5', 'Median', 'P95');
fprintf('%s\n', repmat('-', 1, 80));
for f = 1:4
  x = sum(mc.(fields{f})(valid, :), 2);
  fprintf('%-28s %12.0f %12.0f %12.0f %12.0f %12.0f\n', names{f}, ...
    mean(x), std(x), prctile(x,5), median(x), prctile(x,95));
end

% =========================================================================
% ANNUAL SUMMARY  (Q1+Q2+Q3+Q4 per calendar year, mean over valid iterations)
% =========================================================================
qEndDates = periodDates(2:end);          % end-date of each quarter
[qYears, ~, ~] = datevec(qEndDates);
uniqueYears = unique(qYears);
nYears      = length(uniqueYears);

% For each year: sum the quarterly MC means within the year.
% Equivalent to: mean over valid iters of (sum of quarters in year).
TI_annual       = zeros(nYears, 1);
TI_BOM_annual   = zeros(nYears, 1);
OCI_annual      = zeros(nYears, 1);
CCt_annual      = zeros(nYears, 1);
CCtr_annual     = zeros(nYears, 1);
CCtl_annual     = zeros(nYears, 1);
CCt_LY_annual   = zeros(nYears, 1);
CCtr_LY_annual  = zeros(nYears, 1);
CCtl_LY_annual  = zeros(nYears, 1);

for y = 1:nYears
  qMask = (qYears == uniqueYears(y));
  TI_annual(y)      = mean(sum(mc.FX_trans(valid,        qMask), 2));
  TI_BOM_annual(y)  = mean(sum(mc.FX_trans_BOM(valid,    qMask), 2));
  OCI_annual(y)     = mean(sum(mc.FX_transl(valid,       qMask), 2));
  CCt_annual(y)     = mean(sum(mc.FX_cc_total(valid,     qMask), 2));
  CCtr_annual(y)    = mean(sum(mc.FX_trans_CC(valid,     qMask), 2));
  CCtl_annual(y)    = mean(sum(mc.FX_transl_CC(valid,    qMask), 2));
  CCt_LY_annual(y)  = mean(sum(mc.FX_cc_LY_total(valid,  qMask), 2));
  CCtr_LY_annual(y) = mean(sum(mc.FX_trans_CC_LY(valid,  qMask), 2));
  CCtl_LY_annual(y) = mean(sum(mc.FX_transl_CC_LY(valid, qMask), 2));
end

% Sanity check: CC_trans + CC_transl == CC_total (per year, both methods)
for y = 1:nYears
  err = abs(CCtr_annual(y) + CCtl_annual(y) - CCt_annual(y));
  assert(err < 1e-6, 'CC annual decomposition mismatch for year %d (err=%.2e)', ...
    uniqueYears(y), err);
  err_ly = abs(CCtr_LY_annual(y) + CCtl_LY_annual(y) - CCt_LY_annual(y));
  assert(err_ly < 1e-6, 'CC LY annual decomposition mismatch for year %d (err=%.2e)', ...
    uniqueYears(y), err_ly);
end

fprintf('\n=== PAM — Annual Results (mean over %d iterations, SEK) ===\n', nValid);
fprintf('%-6s %14s %14s %14s %14s %14s %14s\n', ...
  'Year', 'TI (bonds)', 'TI (bonds+BOM)', 'OCI', 'CC_total', 'CC_trans', 'CC_transl');
fprintf('%s\n', repmat('-', 1, 96));
for y = 1:nYears
  fprintf('%-6d %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f\n', ...
    uniqueYears(y), TI_annual(y), TI_BOM_annual(y), OCI_annual(y), ...
    CCt_annual(y), CCtr_annual(y), CCtl_annual(y));
end
fprintf('%s\n', repmat('-', 1, 96));
fprintf('%-6s %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f\n', 'TOTAL', ...
  sum(TI_annual), sum(TI_BOM_annual), sum(OCI_annual), sum(CCt_annual), ...
  sum(CCtr_annual), sum(CCtl_annual));

fprintf('\n=== PAM Constant Currency — Last Year Daily Rates (mean over %d iterations, SEK) ===\n', nValid);
fprintf('%-6s %14s %14s %14s\n', 'Year', 'CC_total_LY', 'CC_trans_LY', 'CC_transl_LY');
fprintf('%s\n', repmat('-', 1, 62));
for y = 1:nYears
  fprintf('%-6d %14.0f %14.0f %14.0f\n', ...
    uniqueYears(y), CCt_LY_annual(y), CCtr_LY_annual(y), CCtl_LY_annual(y));
end
fprintf('%s\n', repmat('-', 1, 62));
fprintf('%-6s %14.0f %14.0f %14.0f\n', 'TOTAL', ...
  sum(CCt_LY_annual), sum(CCtr_LY_annual), sum(CCtl_LY_annual));

% =========================================================================
% PLOTS
% =========================================================================
qLabels = datestr(periodDates(2:end), 'yyyy-Qq');

figure(10); clf;
subplot(4,1,1);
boxplot(mc.FX_trans(valid,:));     set(gca,'XTickLabel',[]); ylabel('SEK');
title('Transactional FX — Bonds only (Eq.4.45)');

subplot(4,1,2);
boxplot(mc.FX_trans_BOM(valid,:)); set(gca,'XTickLabel',[]); ylabel('SEK');
title('Transactional FX — Bonds + BOM');

subplot(4,1,3);
boxplot(mc.FX_transl(valid,:));    set(gca,'XTickLabel',[]); ylabel('SEK');
title('Translation FX per quarter (Eq.4.46)');

subplot(4,1,4);
boxplot(mc.FX_cc(valid,:));        ylabel('SEK');
title('Constant-currency FX per quarter (Eq.4.47)');

sgtitle(sprintf('PAM FX Benchmarks — Monte Carlo (K=%d)', nValid));
