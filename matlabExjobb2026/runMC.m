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
if ~exist('K',    'var'), K    = 200; end

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
mc.FX_trans       = nan(K, nPeriods);   % Transactional FX — Bonds only (Eq. 4.45)
mc.FX_trans_BOM   = nan(K, nPeriods);   % Transactional FX — Bonds + BOM
mc.FX_transl      = nan(K, nPeriods);   % Translation FX per quarter   (Eq. 4.46)
% PAM CC three-way decomposition (Setup A): total = trans + transl + cross
mc.FX_cc_total    = nan(K, nPeriods);   % CC Total per quarter (Eq. 4.47)
mc.FX_cc_trans    = nan(K, nPeriods);   % CC Pure Transaction (foreign at frozen EUR/SEK)
mc.FX_cc_transl   = nan(K, nPeriods);   % CC Pure Translation (EUR/SEK at frozen foreign)
mc.FX_cc_cross    = nan(K, nPeriods);   % CC Cross-rate term (Δfor × ΔEUR/SEK)
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

% --- Flow-restricted PAM CC (performanceAttributionFlowCC) ---------------
% snap  = single-day at recognition (algebraically = M1 CC trans)
% bonds = lifecycle recognition -> payment
% BOM   = lifecycle order -> payment (captures pre-invoice window)
for mode = {'snap','bonds','BOM'}
  m = mode{1};
  for comp = {'trans','transl','cross','total'}
    mc.(sprintf('flowCC_%s_%s', m, comp{1})) = nan(K, nPeriods);
  end
end

mc.seeds       = (1:K)';
mc.periodDates = periodDates;

% =========================================================================
% MONTE CARLO LOOP  (parfor — each worker uses its own simulatedData subfolder)
% =========================================================================
% Pre-load Sandvik data once — avoids slow readcell() on every iteration
sandvikFile = fullfile('marketData', '202605_Sandvik_Data.xlsx');
sandvikArrays.revenueGrowthPct = [NaN, 18.2, NaN(1,19)];
sandvikArrays.grossMarginPct   = [42.5, 43.1, NaN(1,19)];
raw    = readcell(sandvikFile, 'Sheet', 'Income Statement');
revRow = find(cellfun(@(x) ischar(x) && strcmp(x,'Revenue growth, %'), raw(:,1)));
gmRow  = find(cellfun(@(x) ischar(x) && strcmp(x,'Gross Margin'),      raw(:,1)));
for col = 3:21
  v = raw{revRow, col};
  if isnumeric(v) && ~isnan(v), sandvikArrays.revenueGrowthPct(col) = v * 100; end
  v = raw{gmRow,  col};
  if isnumeric(v) && ~isnan(v), sandvikArrays.grossMarginPct(col)   = v * 100; end
end
fprintf('Sandvik data pre-loaded (will not be re-read per iteration).\n\n');

fprintf('Starting Monte Carlo: K=%d, nQuarters=%d\n\n', K, nPeriods);
tStart = tic;

% Collect per-iteration results in a cell array (required for parfor)
results = cell(K, 1);

% Progress counter via DataQueue (parfor-safe; falls back gracefully without PCT)
try
  dq = parallel.pool.DataQueue;
  afterEach(dq, @(k) fprintf('  Seed %4d done  (%.0fs elapsed)\n', k, toc(tStart)));
catch
  dq = [];  % no Parallel Computing Toolbox — progress not printed per-iteration
end

parfor k = 1:K
  % Each parallel worker writes to its own subfolder to avoid file conflicts
  t = getCurrentTask();
  if isempty(t)
    wFolder = 'simulatedData';           % serial fallback (no parallel pool)
  else
    wFolder = fullfile('simulatedData', sprintf('worker_%d', t.ID));
  end

  localSettings            = settings;
  localSettings.dataFolder = wFolder;

  r = struct( ...
    'FX_trans',      nan(1, nPeriods), 'FX_trans_BOM',  nan(1, nPeriods), ...
    'FX_transl',     nan(1, nPeriods), ...
    'FX_cc_total',   nan(1, nPeriods), 'FX_cc_trans',   nan(1, nPeriods), ...
    'FX_cc_transl',  nan(1, nPeriods), 'FX_cc_cross',   nan(1, nPeriods), ...
    'FX_trans_CC_LY',nan(1, nPeriods), 'FX_transl_CC_LY',nan(1, nPeriods), ...
    'FX_cc_LY_total',nan(1, nPeriods), ...
    'M1_TI',  nan(1, nPeriods), 'M1_OCI',  nan(1, nPeriods), ...
    'M2w_TI', nan(1, nPeriods), 'M2w_OCI', nan(1, nPeriods), ...
    'M2m_TI', nan(1, nPeriods), 'M2m_OCI', nan(1, nPeriods), ...
    'M2q_TI', nan(1, nPeriods), 'M2q_OCI', nan(1, nPeriods), ...
    'M1_CC_TI',    nan(1, nPeriods), 'M1_CC_OCI',    nan(1, nPeriods), ...
    'CC_avg_TI',   nan(1, nPeriods), 'CC_avg_OCI',   nan(1, nPeriods), ...
    'CC_close_TI', nan(1, nPeriods), 'CC_close_OCI', nan(1, nPeriods), ...
    'flowCC_snap_trans',  nan(1, nPeriods), 'flowCC_snap_transl',  nan(1, nPeriods), ...
    'flowCC_snap_cross',  nan(1, nPeriods), 'flowCC_snap_total',   nan(1, nPeriods), ...
    'flowCC_bonds_trans', nan(1, nPeriods), 'flowCC_bonds_transl', nan(1, nPeriods), ...
    'flowCC_bonds_cross', nan(1, nPeriods), 'flowCC_bonds_total',  nan(1, nPeriods), ...
    'flowCC_BOM_trans',   nan(1, nPeriods), 'flowCC_BOM_transl',   nan(1, nPeriods), ...
    'flowCC_BOM_cross',   nan(1, nPeriods), 'flowCC_BOM_total',    nan(1, nPeriods));

  createMatFilesSim(dm, k, false, wFolder, sandvikArrays);

  try
    dc = createDataCompany(dm, localSettings);

    % --- PAM --------------------------------------------------------------
    dp = buildPA(dm, dc);
    dr = performanceAttribution(dm, dc, dp, false);

    for p = 1:nPeriods
      idx = quarterIdx{p};
      if ~isempty(idx)
        r.FX_trans(p)     = sum(dr.dFX_trans(idx));
        r.FX_trans_BOM(p) = sum(dr.dFX_trans_BOM(idx));
        r.FX_transl(p)    = sum(dr.dFX_transl(idx));
      end
    end
    r.FX_cc_total      = dr.FX_cc_total_quarterly(:)';
    r.FX_cc_trans      = dr.FX_cc_trans_quarterly(:)';
    r.FX_cc_transl     = dr.FX_cc_transl_quarterly(:)';
    r.FX_cc_cross      = dr.FX_cc_cross_quarterly(:)';
    r.FX_trans_CC_LY   = dr.FX_trans_CC_LY_quarterly(:)';
    r.FX_transl_CC_LY  = dr.FX_transl_CC_LY_quarterly(:)';
    r.FX_cc_LY_total   = dr.FX_cc_LY_total_quarterly(:)';

    % --- Shared accounting core -------------------------------------------
    bs  = buildBalanceSheet(dm, dc);
    pnl = buildFunctionalPnL(dm, dc, bs);

    % --- Method 1 ---------------------------------------------------------
    m1 = computeMethod1(dm, dc, '', bs, pnl);
    r.M1_TI  = m1.TI(:)';
    r.M1_OCI = m1.OCI(:)';

    % --- Method 2 ---------------------------------------------------------
    m2 = computeMethod2(dm, dc, '', bs, pnl);
    r.M2w_TI  = m2.weekly.TI(:)';   r.M2w_OCI = m2.weekly.OCI(:)';
    r.M2m_TI  = m2.monthly.TI(:)';  r.M2m_OCI = m2.monthly.OCI(:)';
    r.M2q_TI  = m2.quarterly.TI(:)';r.M2q_OCI = m2.quarterly.OCI(:)';

    % --- Constant-currency ------------------------------------------------
    P = min(length(m1.cc.avg.quarterly_TI), nPeriods);
    r.M1_CC_TI(1:P)    = m1.cc.M1.quarterly_TI(1:P)';
    r.M1_CC_OCI(1:P)   = m1.cc.M1.quarterly_OCI(1:P)';
    r.CC_avg_TI(1:P)   = m1.cc.avg.quarterly_TI(1:P)';
    r.CC_avg_OCI(1:P)  = m1.cc.avg.quarterly_OCI(1:P)';
    r.CC_close_TI(1:P) = m1.cc.close.quarterly_TI(1:P)';
    r.CC_close_OCI(1:P)= m1.cc.close.quarterly_OCI(1:P)';

    % --- Flow-restricted PAM CC (snap / bonds / BOM) ----------------------
    fcc = performanceAttributionFlowCC(dm, dc, pnl);
    Pf  = min(length(fcc.snap.total_quarterly), nPeriods);
    r.flowCC_snap_trans(1:Pf)  = fcc.snap.trans_quarterly(1:Pf)';
    r.flowCC_snap_transl(1:Pf) = fcc.snap.transl_quarterly(1:Pf)';
    r.flowCC_snap_cross(1:Pf)  = fcc.snap.cross_quarterly(1:Pf)';
    r.flowCC_snap_total(1:Pf)  = fcc.snap.total_quarterly(1:Pf)';
    r.flowCC_bonds_trans(1:Pf)  = fcc.bonds.trans_quarterly(1:Pf)';
    r.flowCC_bonds_transl(1:Pf) = fcc.bonds.transl_quarterly(1:Pf)';
    r.flowCC_bonds_cross(1:Pf)  = fcc.bonds.cross_quarterly(1:Pf)';
    r.flowCC_bonds_total(1:Pf)  = fcc.bonds.total_quarterly(1:Pf)';
    r.flowCC_BOM_trans(1:Pf)    = fcc.BOM.trans_quarterly(1:Pf)';
    r.flowCC_BOM_transl(1:Pf)   = fcc.BOM.transl_quarterly(1:Pf)';
    r.flowCC_BOM_cross(1:Pf)    = fcc.BOM.cross_quarterly(1:Pf)';
    r.flowCC_BOM_total(1:Pf)    = fcc.BOM.total_quarterly(1:Pf)';

  catch ME
    fprintf('  [iter %d] ERROR: %s\n', k, ME.message);
  end

  results{k} = r;
  if ~isempty(dq), send(dq, k); end
end

% Assemble results into mc struct
for k = 1:K
  r = results{k};
  if isempty(r), continue; end
  mc.FX_trans(k,:)      = r.FX_trans;      mc.FX_trans_BOM(k,:)  = r.FX_trans_BOM;
  mc.FX_transl(k,:)     = r.FX_transl;
  mc.FX_cc_total(k,:)   = r.FX_cc_total;   mc.FX_cc_trans(k,:)   = r.FX_cc_trans;
  mc.FX_cc_transl(k,:)  = r.FX_cc_transl;  mc.FX_cc_cross(k,:)   = r.FX_cc_cross;
  mc.FX_trans_CC_LY(k,:) = r.FX_trans_CC_LY;
  mc.FX_transl_CC_LY(k,:)= r.FX_transl_CC_LY;
  mc.FX_cc_LY_total(k,:) = r.FX_cc_LY_total;
  mc.M1_TI(k,:)    = r.M1_TI;    mc.M1_OCI(k,:)    = r.M1_OCI;
  mc.M2w_TI(k,:)   = r.M2w_TI;   mc.M2w_OCI(k,:)   = r.M2w_OCI;
  mc.M2m_TI(k,:)   = r.M2m_TI;   mc.M2m_OCI(k,:)   = r.M2m_OCI;
  mc.M2q_TI(k,:)   = r.M2q_TI;   mc.M2q_OCI(k,:)   = r.M2q_OCI;
  mc.M1_CC_TI(k,:)    = r.M1_CC_TI;    mc.M1_CC_OCI(k,:)    = r.M1_CC_OCI;
  mc.CC_avg_TI(k,:)   = r.CC_avg_TI;   mc.CC_avg_OCI(k,:)   = r.CC_avg_OCI;
  mc.CC_close_TI(k,:) = r.CC_close_TI; mc.CC_close_OCI(k,:) = r.CC_close_OCI;
  for mode = {'snap','bonds','BOM'}
    m = mode{1};
    for comp = {'trans','transl','cross','total'}
      fn = sprintf('flowCC_%s_%s', m, comp{1});
      mc.(fn)(k,:) = r.(fn);
    end
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
fprintf('%-12s %14s %14s %14s\n', 'Quarter end', 'Transactional', 'Translation', 'CC Total');
fprintf('%s\n', repmat('-', 1, 58));
for p = 1:nPeriods
  fprintf('%-12s %14.0f %14.0f %14.0f\n', ...
    datestr(periodDates(p+1), 'yyyy-mm-dd'), ...
    mean(mc.FX_trans(valid, p)), ...
    mean(mc.FX_transl(valid, p)), ...
    mean(mc.FX_cc_total(valid, p)));
end

fprintf('\n=== Full-period totals (sum of quarters) ===\n');
names  = {'Trans — Bonds only (Eq.4.45)', 'Trans — Bonds+BOM      ', 'Translation   (Eq.4.46)', 'CC Total       (Eq.4.47)'};
fields = {'FX_trans', 'FX_trans_BOM', 'FX_transl', 'FX_cc_total'};
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
CCt_annual      = zeros(nYears, 1);   % CC Total
CCtr_annual     = zeros(nYears, 1);   % CC Pure Transaction
CCtl_annual     = zeros(nYears, 1);   % CC Pure Translation
CCx_annual      = zeros(nYears, 1);   % CC Cross
CCt_LY_annual   = zeros(nYears, 1);
CCtr_LY_annual  = zeros(nYears, 1);
CCtl_LY_annual  = zeros(nYears, 1);

for y = 1:nYears
  qMask = (qYears == uniqueYears(y));
  TI_annual(y)      = mean(sum(mc.FX_trans(valid,        qMask), 2));
  TI_BOM_annual(y)  = mean(sum(mc.FX_trans_BOM(valid,    qMask), 2));
  OCI_annual(y)     = mean(sum(mc.FX_transl(valid,       qMask), 2));
  CCt_annual(y)     = mean(sum(mc.FX_cc_total(valid,     qMask), 2));
  CCtr_annual(y)    = mean(sum(mc.FX_cc_trans(valid,     qMask), 2));
  CCtl_annual(y)    = mean(sum(mc.FX_cc_transl(valid,    qMask), 2));
  CCx_annual(y)     = mean(sum(mc.FX_cc_cross(valid,     qMask), 2));
  CCt_LY_annual(y)  = mean(sum(mc.FX_cc_LY_total(valid,  qMask), 2));
  CCtr_LY_annual(y) = mean(sum(mc.FX_trans_CC_LY(valid,  qMask), 2));
  CCtl_LY_annual(y) = mean(sum(mc.FX_transl_CC_LY(valid, qMask), 2));
end

% Hard assertion: CC_trans + CC_transl + CC_cross == CC_total (per year, three-way)
for y = 1:nYears
  err = abs(CCtr_annual(y) + CCtl_annual(y) + CCx_annual(y) - CCt_annual(y));
  assert(err < 1e-5, 'PAM CC three-way annual decomposition mismatch for year %d (err=%.2e)', ...
    uniqueYears(y), err);
  err_ly = abs(CCtr_LY_annual(y) + CCtl_LY_annual(y) - CCt_LY_annual(y));
  assert(err_ly < 1e-5, 'CC LY annual decomposition mismatch for year %d (err=%.2e)', ...
    uniqueYears(y), err_ly);
end

fprintf('\n=== PAM — Annual Results (mean over %d iterations, SEK) ===\n', nValid);
fprintf('%-6s %14s %14s %14s %14s %14s %14s %14s\n', ...
  'Year', 'TI (bonds)', 'TI (bonds+BOM)', 'OCI', 'CC_total', 'CC_trans', 'CC_transl', 'CC_cross');
fprintf('%s\n', repmat('-', 1, 110));
for y = 1:nYears
  fprintf('%-6d %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f\n', ...
    uniqueYears(y), TI_annual(y), TI_BOM_annual(y), OCI_annual(y), ...
    CCt_annual(y), CCtr_annual(y), CCtl_annual(y), CCx_annual(y));
end
fprintf('%s\n', repmat('-', 1, 110));
fprintf('%-6s %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f %14.0f\n', 'TOTAL', ...
  sum(TI_annual), sum(TI_BOM_annual), sum(OCI_annual), sum(CCt_annual), ...
  sum(CCtr_annual), sum(CCtl_annual), sum(CCx_annual));

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
boxplot(mc.FX_cc_total(valid,:));  ylabel('SEK');
title('Constant-currency FX Total per quarter (Eq.4.47)');

sgtitle(sprintf('PAM FX Benchmarks — Monte Carlo (K=%d)', nValid));

% =========================================================================
% ERROR TERM ANALYSIS
% Quarterly errors [nValid x nPeriods] — ME and RMSE over all K*nPeriods
% observations, preserving the full quarterly structure.
% Summing over 19 years before comparing would let errors cancel across
% time periods and hide systematic quarterly biases.
% =========================================================================

% Extract quarterly matrices [nValid x nPeriods]
qV = @(field) mc.(field)(valid,:);

PAM_TI_q     = qV('FX_trans');
PAM_TI_BOM_q = qV('FX_trans_BOM');
PAM_OCI_q    = qV('FX_transl');
M1_TI_q      = qV('M1_TI');
M1_OCI_q     = qV('M1_OCI');
M2w_TI_q     = qV('M2w_TI');   M2w_OCI_q = qV('M2w_OCI');
M2m_TI_q     = qV('M2m_TI');   M2m_OCI_q = qV('M2m_OCI');
M2q_TI_q     = qV('M2q_TI');   M2q_OCI_q = qV('M2q_OCI');
fSnap_q      = qV('flowCC_snap_total');
fBonds_q     = qV('flowCC_bonds_total');
fBOM_q       = qV('flowCC_BOM_total');
M1_CC_q      = qV('M1_CC_TI');

% Error stats over all K*nPeriods quarterly observations.
% ME      = mean quarterly error (systematic bias)       Eq. (me)
% CI      = 95% CI for ME via CLT: ME ± 1.96*s/sqrt(N)  Eq. (ci)
% RMSE    = root mean squared quarterly error             Eq. (rmse)
% Corr    = correlation across all K*nPeriods obs
% KDE bw  = Silverman rule: 0.9*min(sigma,IQR/1.34)*N^(-1/5)  Eq. (silverman)
printRow = @(label, A, B) printErrRow(label, A(:), B(:));
kdeplot  = @(ax, e, lbl, col) plotSilvermanKDE(ax, e, lbl, col);

% =========================================================================
% TABLE 1 — Transactional Impact: PAM vs M1 vs M2
% =========================================================================
fprintf('\n%s\n', repmat('=',1,95));
fprintf('ERROR TERMS — Transactional Impact (TI)\n');
fprintf('Based on %d quarterly observations (%d iterations x %d quarters)\n', ...
  nValid*nPeriods, nValid, nPeriods);
fprintf('Benchmark: PAM Bonds\n');
printHeader();

printRow('PAM bonds  vs  M1',          PAM_TI_q,     M1_TI_q);
printRow('PAM bonds  vs  M2 weekly',   PAM_TI_q,     M2w_TI_q);
printRow('PAM bonds  vs  M2 monthly',  PAM_TI_q,     M2m_TI_q);
printRow('PAM bonds  vs  M2 quarterly',PAM_TI_q,     M2q_TI_q);
printRow('M1         vs  M2 weekly',   M1_TI_q,      M2w_TI_q);
printRow('M1         vs  M2 monthly',  M1_TI_q,      M2m_TI_q);
printRow('M1         vs  M2 quarterly',M1_TI_q,      M2q_TI_q);
printRow('PAM BOM    vs  M1',          PAM_TI_BOM_q, M1_TI_q);

% =========================================================================
% TABLE 2 — Translation / OCI: PAM vs M1 vs M2
% =========================================================================
fprintf('\n%s\n', repmat('=',1,105));
fprintf('ERROR TERMS — Translation / OCI\n');
fprintf('Based on %d quarterly observations (%d iterations x %d quarters)\n', ...
  nValid*nPeriods, nValid, nPeriods);
fprintf('Benchmark: PAM Translation\n');
printHeader();

printRow('PAM transl  vs  M1 OCI',    PAM_OCI_q, M1_OCI_q);
printRow('PAM transl  vs  M2 weekly', PAM_OCI_q, M2w_OCI_q);
printRow('PAM transl  vs  M2 monthly',PAM_OCI_q, M2m_OCI_q);
printRow('PAM transl  vs  M2 qtrly', PAM_OCI_q, M2q_OCI_q);
printRow('M1 OCI      vs  M2 weekly', M1_OCI_q,  M2w_OCI_q);
printRow('M1 OCI      vs  M2 monthly',M1_OCI_q,  M2m_OCI_q);
printRow('M1 OCI      vs  M2 qtrly', M1_OCI_q,  M2q_OCI_q);

% =========================================================================
% TABLE 3 — Constant Currency: PAM flow CC vs M1 CC
% =========================================================================
fprintf('\n%s\n', repmat('=',1,105));
fprintf('ERROR TERMS — Constant Currency (CC)\n');
fprintf('Based on %d quarterly observations (%d iterations x %d quarters)\n', ...
  nValid*nPeriods, nValid, nPeriods);
fprintf('Benchmark: M1 CC\n');
printHeader();

printRow('PAM flow snap  vs  M1 CC',  fSnap_q,  M1_CC_q);
printRow('PAM flow bonds vs  M1 CC',  fBonds_q, M1_CC_q);
printRow('PAM flow BOM   vs  M1 CC',  fBOM_q,   M1_CC_q);
printRow('PAM flow bonds vs  snap',   fBonds_q, fSnap_q);
printRow('PAM flow BOM   vs  bonds',  fBOM_q,   fBonds_q);

% =========================================================================
% PLOTS — Quarterly error distributions
% =========================================================================

% --- Figure 11: TI quarterly errors across all K*nPeriods obs -------------
figure(11); clf;
err_TI_M1  = (PAM_TI_q - M1_TI_q)  / 1e6;  % [nValid x nPeriods]
err_TI_M2w = (PAM_TI_q - M2w_TI_q) / 1e6;
err_TI_M2m = (PAM_TI_q - M2m_TI_q) / 1e6;
err_TI_M2q = (PAM_TI_q - M2q_TI_q) / 1e6;

subplot(2,1,1);
allErrs = [err_TI_M1(:), err_TI_M2w(:), err_TI_M2m(:), err_TI_M2q(:)];
boxplot(allErrs, 'Labels', {'PAM-M1','PAM-M2w','PAM-M2m','PAM-M2q'});
yline(0,'k--'); ylabel('SEK million');
title(sprintf('TI quarterly error distribution (%d obs each)', nValid*nPeriods));

subplot(2,1,2);
% Mean quarterly error per quarter (averaged over K iterations)
plot(mean(err_TI_M1,1),  'b-o', 'MarkerSize', 3); hold on;
plot(mean(err_TI_M2m,1), 'g-o', 'MarkerSize', 3);
plot(mean(err_TI_M2q,1), 'r-o', 'MarkerSize', 3);
yline(0,'k--');
legend('PAM-M1','PAM-M2m','PAM-M2q','Location','Best');
ylabel('SEK million'); xlabel('Quarter');
title('Mean TI error per quarter (averaged over K iterations)');
sgtitle(sprintf('Transactional Impact — Quarterly Error Analysis (K=%d)', nValid));

% --- Figure 12: M2 averaging window comparison ----------------------------
figure(12); clf;
subplot(2,1,1);
m2e_TI = [(M1_TI_q-M2w_TI_q)(:), (M1_TI_q-M2m_TI_q)(:), (M1_TI_q-M2q_TI_q)(:)] / 1e6;
boxplot(m2e_TI, 'Labels', {'M1-M2 weekly','M1-M2 monthly','M1-M2 quarterly'});
yline(0,'k--'); ylabel('SEK million');
title(sprintf('TI: M1 vs M2 by averaging window (%d quarterly obs)', nValid*nPeriods));

subplot(2,1,2);
m2e_OCI = [(M1_OCI_q-M2w_OCI_q)(:), (M1_OCI_q-M2m_OCI_q)(:), (M1_OCI_q-M2q_OCI_q)(:)] / 1e6;
boxplot(m2e_OCI, 'Labels', {'M1-M2 weekly','M1-M2 monthly','M1-M2 quarterly'});
yline(0,'k--'); ylabel('SEK million');
title(sprintf('OCI: M1 vs M2 by averaging window (%d quarterly obs)', nValid*nPeriods));
sgtitle(sprintf('Industry Method Comparison: M1 vs M2 (K=%d)', nValid));

% --- Figure 13: PAM flow CC modes vs M1 CC --------------------------------
figure(13); clf;
err_snap  = (fSnap_q  - M1_CC_q) / 1e6;
err_bonds = (fBonds_q - M1_CC_q) / 1e6;
err_BOM   = (fBOM_q   - M1_CC_q) / 1e6;

subplot(2,1,1);
boxplot([err_snap(:), err_bonds(:), err_BOM(:)], ...
  'Labels', {'snap-M1CC','bonds-M1CC','BOM-M1CC'});
yline(0,'k--'); ylabel('SEK million');
title(sprintf('CC quarterly error vs M1 CC (%d obs each)', nValid*nPeriods));

subplot(2,1,2);
plot(mean(err_snap,1),  'b-o', 'MarkerSize', 3); hold on;
plot(mean(err_bonds,1), 'r-o', 'MarkerSize', 3);
plot(mean(err_BOM,1),   'g-o', 'MarkerSize', 3);
yline(0,'k--');
legend('snap-M1CC','bonds-M1CC','BOM-M1CC','Location','Best');
ylabel('SEK million'); xlabel('Quarter');
title('Mean CC error per quarter (averaged over K iterations)');
sgtitle(sprintf('Constant Currency — PAM flow modes vs M1 CC (K=%d)', nValid));

% =========================================================================
% KDE PLOTS — Silverman bandwidth: h = 0.9*min(sigma,IQR/1.34)*N^(-1/5)
% Overlaid distributions allow direct comparison of how error changes
% with averaging interval (Eq. silverman_method, Sawitzki 1999).
% =========================================================================
colors = {[0.12 0.47 0.71],[0.20 0.63 0.17],[0.89 0.10 0.11],[0.60 0.40 0.12]};

% --- Figure 14: TI KDE ---------------------------------------------------
figure(14); clf; hold on;
kdeplot(gca, err_TI_M1(:),  'PAM bonds vs M1',       colors{1});
kdeplot(gca, err_TI_M2w(:), 'PAM bonds vs M2 weekly',colors{2});
kdeplot(gca, err_TI_M2m(:), 'PAM bonds vs M2 monthly',colors{3});
kdeplot(gca, err_TI_M2q(:), 'PAM bonds vs M2 quarterly',colors{4});
xline(0,'k--'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on;
title(sprintf('TI error KDE — Silverman bandwidth (N=%d obs)', nValid*nPeriods));

% --- Figure 15: OCI KDE --------------------------------------------------
err_OCI_M1  = (PAM_OCI_q - M1_OCI_q)  / 1e6;
err_OCI_M2w = (PAM_OCI_q - M2w_OCI_q) / 1e6;
err_OCI_M2m = (PAM_OCI_q - M2m_OCI_q) / 1e6;
err_OCI_M2q = (PAM_OCI_q - M2q_OCI_q) / 1e6;

figure(15); clf; hold on;
kdeplot(gca, err_OCI_M1(:),  'PAM transl vs M1 OCI',        colors{1});
kdeplot(gca, err_OCI_M2w(:), 'PAM transl vs M2 weekly OCI', colors{2});
kdeplot(gca, err_OCI_M2m(:), 'PAM transl vs M2 monthly OCI',colors{3});
kdeplot(gca, err_OCI_M2q(:), 'PAM transl vs M2 qtrly OCI',  colors{4});
xline(0,'k--'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on;
title(sprintf('OCI error KDE — Silverman bandwidth (N=%d obs)', nValid*nPeriods));

% --- Figure 16: CC KDE ---------------------------------------------------
figure(16); clf; hold on;
kdeplot(gca, err_snap(:),  'snap vs M1 CC',  colors{1});
kdeplot(gca, err_bonds(:), 'bonds vs M1 CC', colors{2});
kdeplot(gca, err_BOM(:),   'BOM vs M1 CC',   colors{3});
xline(0,'k--'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on;
title(sprintf('CC error KDE — Silverman bandwidth (N=%d obs)', nValid*nPeriods));

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================
function printHeader()
  fprintf('%s\n', repmat('=',1,105));
  fprintf('%-32s %14s   %-27s  %14s  %8s\n', ...
    'Method pair','ME (SEK)','95% CI (SEK)','RMSE (SEK)','Corr');
  fprintf('%s\n', repmat('-',1,105));
end

function printErrRow(label, A, B)
  e     = A - B;
  N     = numel(e);
  me    = mean(e);
  rmse  = sqrt(mean(e.^2));
  s     = std(e);
  ci_hw = 1.96 * s / sqrt(N);
  cr    = corr(A, B);
  fprintf('%-32s %14.0f   [%12.0f, %12.0f]  %14.0f  %8.4f\n', ...
    label, me, me-ci_hw, me+ci_hw, rmse, cr);
end

function plotSilvermanKDE(ax, e, lbl, col)
  N  = numel(e);
  s  = std(e);
  h  = 0.9 * min(s, iqr(e)/1.34) * N^(-1/5);
  [f, xi] = ksdensity(e, 'Bandwidth', h);
  plot(ax, xi, f, 'Color', col, 'LineWidth', 1.8, 'DisplayName', lbl);
end
