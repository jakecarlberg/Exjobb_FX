% runMC  Monte Carlo driver — PAM + Method 1 + Method 2 FX analysis
%
% Runs K iterations of the full pipeline:
%   createMatFilesSim -> createDataCompany -> buildPA -> performanceAttribution
%                                          -> buildBalanceSheet/buildFunctionalPnL
%                                          -> computeMethod1 / computeMethod2
%
% Market data (dm) is loaded once and kept fixed across all iterations.
% Transaction datasets are randomised per seed.
%
% bs and pnl are computed once per iteration and passed to both industry
% methods to avoid redundant work.
%
% Results are stored per quarter [K x nPeriods] for all methods.
% Each seed is saved to mc_checkpoints/ so a run can resume after interruption.
%
% Usage:
%   runMC              % default K=200
%   K = 1000; runMC    % override before running

% =========================================================================
% SETTINGS
% =========================================================================
if ~exist('K',    'var'), K    = 2; end

% -------------------------------------------------------------------------
% DISTRIBUTED RUN — optional, leave commented out to run all seeds locally
% -------------------------------------------------------------------------
% To run a single machine over ALL seeds 1:K (default), leave the line
% below commented out. To split the workload across multiple machines,
% uncomment and set `seeds` to the range this machine should handle, e.g.:
%
%   Machine A:  seeds = 1:500;        % first half
%   Machine B:  seeds = 501:1000;     % second half
%
% Both machines must write checkpoints into the same `mc_checkpoints/`
% folder (network share, OneDrive, etc.) or have their folders merged
% before final aggregation. Filenames embed the seed number, so there is
% no collision between machines.
%
% The in-script summary tables at the end will only count THIS machine's
% seeds. To get the combined summary across both halves, copy/merge the
% checkpoints into one folder and re-run runMC with `seeds` UNSET (and
% `clear seeds` first if needed). The parfor will skip every seed via the
% existing "checkpoint exists" path, then aggregation runs over 1:K.
%
% seeds = 1:500;    %  <-- uncomment and edit this line to split work
% -------------------------------------------------------------------------
if ~exist('seeds', 'var'), seeds = 1:K; end

settings.dataFolder         = 'simulatedData';
settings.bomPricing         = 'DeterministicCashFlows';
settings.curFunctional      = 'EUR';
settings.startDate          = datenum(2006,1,1);  % 1 year before sim start so 2007 CC has 2006 comparison rates
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Currencies used in simulation (INR excluded — yield curve history too short)
settings.currencies         = {'AUD','CAD','CNY','EUR','SEK','USD','ZAR'};

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

% Years spanned by simulation (2007-2025)
qYears_pre  = year(datetime(periodDates(1:end-1), 'ConvertFrom', 'datenum'));
uniqueYears = unique(qYears_pre);
nYears_mc   = length(uniqueYears);
nCur_mc     = 6;  % matches saleExposurePct in createMatFilesSim

% =========================================================================
% PRE-ALLOCATE RESULT ARRAYS  [K x nPeriods]
% =========================================================================

% --- Simulation validation (revenue, GM, currency exposure) ---------------
mc.actRevEUR  = nan(K, nYears_mc);        % actual revenue per year [EUR]
mc.actGMpct   = nan(K, nYears_mc);        % actual gross margin % per year
mc.netExpPct  = nan(K, nYears_mc, nCur_mc); % net FX exposure % per year per currency

% --- PAM benchmarks -------------------------------------------------------
mc.FX_trans       = nan(K, nPeriods);   % Transactional FX — Bonds only
mc.FX_trans_BOM   = nan(K, nPeriods);   % Transactional FX — Bonds + BOM
mc.FX_transl      = nan(K, nPeriods);   % Translation FX per quarter
% --- Stock-based PAM CC DISABLED (flow-restricted BOM is the truth) ------
% mc.FX_cc_total    = nan(K, nPeriods);   % CC Total per quarter
% mc.FX_cc_trans    = nan(K, nPeriods);   % CC Pure Transaction (foreign rates frozen)
% mc.FX_cc_transl   = nan(K, nPeriods);   % CC Pure Translation (EUR/SEK frozen)
% mc.FX_cc_cross    = nan(K, nPeriods);   % CC Cross-rate term
% mc.FX_trans_CC_LY  = nan(K, nPeriods);
% mc.FX_transl_CC_LY = nan(K, nPeriods);
% mc.FX_cc_LY_total  = nan(K, nPeriods);

% --- Method 1 (actual daily rate) ----------------------------------------
mc.M1_TI  = nan(K, nPeriods);   % Transactional Impact
mc.M1_OCI = nan(K, nPeriods);   % Translation Impact / OCI

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
% snap   = rate at recognition date  -- DISABLED (algebraically = industry CC TI)
% bonds  = rate over recognition -> payment window
% BOM    = rate over order -> payment window (conventional CC semantics;
%          cumulative identical to bonds — only timing redistributes)
% BOMext = bonds + extra BOM-phase deviation accumulation (TI-BOM-like
%          semantics; cumulative differs from bonds by the per-event
%          F(t_rec)-F(t_ord) drift summed over all events)
for mode = {'bonds','BOM','BOMext'}
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

% Checkpoint folder — each seed saved to disk so runs survive interruption
ckptDir = 'mc_checkpoints';
if ~exist(ckptDir, 'dir'), mkdir(ckptDir); end

% Count completed seeds by scanning the folder (not just 1:K, so seeds
% with numbers above K are also detected and reported correctly).
ckptFiles = dir(fullfile(ckptDir, 'seed_*.mat'));
nDone = length(ckptFiles);
if nDone > 0
  fprintf('Resuming: %d/%d seeds already done (found in %s)\n\n', nDone, K, ckptDir);
end

if isequal(seeds, 1:K)
  fprintf('Starting Monte Carlo: K=%d, nQuarters=%d\n\n', K, nPeriods);
else
  fprintf('Starting Monte Carlo: K=%d total, this machine runs seeds %d:%d (%d iters), nQuarters=%d\n\n', ...
    K, min(seeds), max(seeds), length(seeds), nPeriods);
end
tStart = tic;

% Collect per-iteration results in a cell array (required for parfor).
% Indexed by ii (1..length(seeds)) inside parfor so the slicing classifier
% works; scattered back to a K-sized `results` cell after the parfor for
% downstream code that assumes `results{k}` with k in 1..K.
results     = cell(K, 1);
seedResults = cell(length(seeds), 1);

% Progress counter via DataQueue (parfor-safe; skipped if no PCT)
try
  dq = parallel.pool.DataQueue;
  afterEach(dq, @(k) fprintf('  Seed %4d done  (%.0fs elapsed)\n', k, toc(tStart)));
catch
  dq = [];
end

% Iterate over `seeds` (a subset of 1:K) — see SETTINGS block above for
% how to split a run across multiple machines.
parfor ii = 1:length(seeds)
  k = seeds(ii);
  ckptFile = fullfile(ckptDir, sprintf('seed_%04d.mat', k));

  if exist(ckptFile, 'file')
    % Already computed — load from disk and skip
    tmp = load(ckptFile, 'r');
    r   = tmp.r;
    % Patch fields missing from old checkpoints
    if ~isfield(r, 'actRevEUR'), r.actRevEUR = nan(1, nYears_mc); end
    if ~isfield(r, 'actGMpct'),  r.actGMpct  = nan(1, nYears_mc); end
    if ~isfield(r, 'netExpPct'), r.netExpPct = nan(nYears_mc, nCur_mc); end
    seedResults{ii} = r;
  else
    % Each parallel worker writes to its own subfolder to avoid file conflicts
    t = getCurrentTask();
    if isempty(t)
      wFolder = 'simulatedData';
    else
      wFolder = fullfile('simulatedData', sprintf('worker_%d', t.ID));
    end

    localSettings            = settings;
    localSettings.dataFolder = wFolder;

    % DISABLED: stock-based PAM CC (FX_cc_*, FX_*_CC_LY, FX_cc_LY_total)
    %           snap mode of flow CC (flowCC_snap_*)
    r = struct( ...
      'FX_trans',      nan(1, nPeriods), 'FX_trans_BOM',  nan(1, nPeriods), ...
      'FX_transl',     nan(1, nPeriods), ...
      'M1_TI',  nan(1, nPeriods), 'M1_OCI',  nan(1, nPeriods), ...
      'M2w_TI', nan(1, nPeriods), 'M2w_OCI', nan(1, nPeriods), ...
      'M2m_TI', nan(1, nPeriods), 'M2m_OCI', nan(1, nPeriods), ...
      'M2q_TI', nan(1, nPeriods), 'M2q_OCI', nan(1, nPeriods), ...
      'M1_CC_TI',    nan(1, nPeriods), 'M1_CC_OCI',    nan(1, nPeriods), ...
      'CC_avg_TI',   nan(1, nPeriods), 'CC_avg_OCI',   nan(1, nPeriods), ...
      'CC_close_TI', nan(1, nPeriods), 'CC_close_OCI', nan(1, nPeriods), ...
      'flowCC_bonds_trans',  nan(1, nPeriods), 'flowCC_bonds_transl',  nan(1, nPeriods), ...
      'flowCC_bonds_cross',  nan(1, nPeriods), 'flowCC_bonds_total',   nan(1, nPeriods), ...
      'flowCC_BOM_trans',    nan(1, nPeriods), 'flowCC_BOM_transl',    nan(1, nPeriods), ...
      'flowCC_BOM_cross',    nan(1, nPeriods), 'flowCC_BOM_total',     nan(1, nPeriods), ...
      'flowCC_BOMext_trans', nan(1, nPeriods), 'flowCC_BOMext_transl', nan(1, nPeriods), ...
      'flowCC_BOMext_cross', nan(1, nPeriods), 'flowCC_BOMext_total',  nan(1, nPeriods), ...
      'actRevEUR',  nan(1, nYears_mc), 'actGMpct',  nan(1, nYears_mc), ...
      'netExpPct',  nan(nYears_mc, nCur_mc));

    createMatFilesSim(dm, k, false, wFolder, sandvikArrays);

    % Load simulation validation summary
    try
      tmp_ss = load(fullfile(wFolder, 'simSummary'), 'simSummary');
      ss = tmp_ss.simSummary;
      r.actRevEUR = ss.actRevenue;
      r.actGMpct  = 100 * (1 - ss.actCOGS ./ ss.actRevenue);
      netRev      = ss.curRevenue - ss.curCOGS;   % [nYears x nCur] EUR
      r.netExpPct = 100 * (netRev ./ ss.actRevenue');
    catch
    end

    try
      dc = createDataCompany(dm, localSettings);

      % --- PAM ------------------------------------------------------------
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
      % --- Stock-based PAM CC DISABLED (replaced by flow-restricted BOM) -
      % r.FX_cc_total      = dr.FX_cc_total_quarterly(:)';
      % r.FX_cc_trans      = dr.FX_cc_trans_quarterly(:)';
      % r.FX_cc_transl     = dr.FX_cc_transl_quarterly(:)';
      % r.FX_cc_cross      = dr.FX_cc_cross_quarterly(:)';
      % r.FX_trans_CC_LY   = dr.FX_trans_CC_LY_quarterly(:)';
      % r.FX_transl_CC_LY  = dr.FX_transl_CC_LY_quarterly(:)';
      % r.FX_cc_LY_total   = dr.FX_cc_LY_total_quarterly(:)';

      % --- Shared accounting core -----------------------------------------
      bs  = buildBalanceSheet(dm, dc);
      pnl = buildFunctionalPnL(dm, dc, bs);

      % --- Method 1 -------------------------------------------------------
      m1 = computeMethod1(dm, dc, '', bs, pnl);
      r.M1_TI  = m1.TI(:)';
      r.M1_OCI = m1.OCI(:)';

      % --- Method 2 -------------------------------------------------------
      m2 = computeMethod2(dm, dc, '', bs, pnl);
      r.M2w_TI  = m2.weekly.TI(:)';    r.M2w_OCI = m2.weekly.OCI(:)';
      r.M2m_TI  = m2.monthly.TI(:)';   r.M2m_OCI = m2.monthly.OCI(:)';
      r.M2q_TI  = m2.quarterly.TI(:)'; r.M2q_OCI = m2.quarterly.OCI(:)';

      % --- Constant-currency ----------------------------------------------
      P = min(length(m1.cc.avg.quarterly_TI), nPeriods);
      r.M1_CC_TI(1:P)    = m1.cc.M1.quarterly_TI(1:P)';
      r.M1_CC_OCI(1:P)   = m1.cc.M1.quarterly_OCI(1:P)';
      r.CC_avg_TI(1:P)   = m1.cc.avg.quarterly_TI(1:P)';
      r.CC_avg_OCI(1:P)  = m1.cc.avg.quarterly_OCI(1:P)';
      r.CC_close_TI(1:P) = m1.cc.close.quarterly_TI(1:P)';
      r.CC_close_OCI(1:P)= m1.cc.close.quarterly_OCI(1:P)';

      % --- Flow-restricted PAM CC (bonds / BOM; snap DISABLED) -----------
      fcc = performanceAttributionFlowCC(dm, dc, pnl);
      Pf  = min(length(fcc.bonds.total_quarterly), nPeriods);
      % r.flowCC_snap_trans(1:Pf)   = fcc.snap.trans_quarterly(1:Pf)';
      % r.flowCC_snap_transl(1:Pf)  = fcc.snap.transl_quarterly(1:Pf)';
      % r.flowCC_snap_cross(1:Pf)   = fcc.snap.cross_quarterly(1:Pf)';
      % r.flowCC_snap_total(1:Pf)   = fcc.snap.total_quarterly(1:Pf)';
      r.flowCC_bonds_trans(1:Pf)   = fcc.bonds.trans_quarterly(1:Pf)';
      r.flowCC_bonds_transl(1:Pf)  = fcc.bonds.transl_quarterly(1:Pf)';
      r.flowCC_bonds_cross(1:Pf)   = fcc.bonds.cross_quarterly(1:Pf)';
      r.flowCC_bonds_total(1:Pf)   = fcc.bonds.total_quarterly(1:Pf)';
      r.flowCC_BOM_trans(1:Pf)     = fcc.BOM.trans_quarterly(1:Pf)';
      r.flowCC_BOM_transl(1:Pf)    = fcc.BOM.transl_quarterly(1:Pf)';
      r.flowCC_BOM_cross(1:Pf)     = fcc.BOM.cross_quarterly(1:Pf)';
      r.flowCC_BOM_total(1:Pf)     = fcc.BOM.total_quarterly(1:Pf)';
      r.flowCC_BOMext_trans(1:Pf)  = fcc.BOMext.trans_quarterly(1:Pf)';
      r.flowCC_BOMext_transl(1:Pf) = fcc.BOMext.transl_quarterly(1:Pf)';
      r.flowCC_BOMext_cross(1:Pf)  = fcc.BOMext.cross_quarterly(1:Pf)';
      r.flowCC_BOMext_total(1:Pf)  = fcc.BOMext.total_quarterly(1:Pf)';

    catch ME
      fprintf('  [iter %d] ERROR: %s\n', k, ME.message);
    end

    % Save checkpoint so this seed is not recomputed on restart
    saveCheckpoint(ckptFile, r);
    seedResults{ii} = r;
  end

  if ~isempty(dq), send(dq, k); end
end

% Scatter parfor-local seedResults back into the K-sized results cell so
% downstream aggregation (for k = 1:K) works whether seeds == 1:K or a
% subset. Slots for seeds NOT in this machine's range stay empty and the
% existing "if isempty(r), continue" check in the loop below skips them.
for ii = 1:length(seeds)
  results{seeds(ii)} = seedResults{ii};
end

% Assemble results into mc struct
for k = 1:K
  r = results{k};
  if isempty(r), continue; end
  mc.actRevEUR(k,:)    = r.actRevEUR;
  mc.actGMpct(k,:)     = r.actGMpct;
  mc.netExpPct(k,:,:)  = r.netExpPct;
  mc.FX_trans(k,:)      = r.FX_trans;      mc.FX_trans_BOM(k,:)  = r.FX_trans_BOM;
  mc.FX_transl(k,:)     = r.FX_transl;
  % --- Stock-based PAM CC DISABLED --------------------------------------
  % mc.FX_cc_total(k,:)   = r.FX_cc_total;   mc.FX_cc_trans(k,:)   = r.FX_cc_trans;
  % mc.FX_cc_transl(k,:)  = r.FX_cc_transl;  mc.FX_cc_cross(k,:)   = r.FX_cc_cross;
  % mc.FX_trans_CC_LY(k,:) = r.FX_trans_CC_LY;
  % mc.FX_transl_CC_LY(k,:)= r.FX_transl_CC_LY;
  % mc.FX_cc_LY_total(k,:) = r.FX_cc_LY_total;
  mc.M1_TI(k,:)    = r.M1_TI;    mc.M1_OCI(k,:)    = r.M1_OCI;
  mc.M2w_TI(k,:)   = r.M2w_TI;   mc.M2w_OCI(k,:)   = r.M2w_OCI;
  mc.M2m_TI(k,:)   = r.M2m_TI;   mc.M2m_OCI(k,:)   = r.M2m_OCI;
  mc.M2q_TI(k,:)   = r.M2q_TI;   mc.M2q_OCI(k,:)   = r.M2q_OCI;
  mc.M1_CC_TI(k,:)    = r.M1_CC_TI;    mc.M1_CC_OCI(k,:)    = r.M1_CC_OCI;
  mc.CC_avg_TI(k,:)   = r.CC_avg_TI;   mc.CC_avg_OCI(k,:)   = r.CC_avg_OCI;
  mc.CC_close_TI(k,:) = r.CC_close_TI; mc.CC_close_OCI(k,:) = r.CC_close_OCI;
  for mode = {'bonds','BOM','BOMext'}   % 'snap' DISABLED
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
        ~any(isnan(mc.M1_TI),  2) & ...
        ~any(isnan(mc.M2m_TI), 2);
nValid = sum(valid);

fprintf('\n=== PAM FX Benchmarks: mean per quarter across %d iterations (SEK) ===\n', nValid);
fprintf('%-12s %14s %14s\n', 'Quarter end', 'Transactional', 'Translation');
fprintf('%s\n', repmat('-', 1, 44));
for p = 1:nPeriods
  fprintf('%-12s %14.0f %14.0f\n', ...
    datestr(periodDates(p+1), 'yyyy-mm-dd'), ...
    mean(mc.FX_trans(valid, p)), ...
    mean(mc.FX_transl(valid, p)));
end

fprintf('\n=== Full-period totals (sum of quarters) ===\n');
names  = {'Trans — Bonds only      ', 'Trans — Bonds+BOM      ', 'Translation             '};
fields = {'FX_trans', 'FX_trans_BOM', 'FX_transl'};
fprintf('%-28s %12s %12s %12s %12s %12s\n', '', 'Mean', 'Std', 'P5', 'Median', 'P95');
fprintf('%s\n', repmat('-', 1, 80));
for f = 1:length(fields)
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

% For each year: mean over valid iterations of the sum across quarters.
TI_annual       = zeros(nYears, 1);
TI_BOM_annual   = zeros(nYears, 1);
OCI_annual      = zeros(nYears, 1);

for y = 1:nYears
  qMask = (qYears == uniqueYears(y));
  TI_annual(y)      = mean(sum(mc.FX_trans(valid,     qMask), 2));
  TI_BOM_annual(y)  = mean(sum(mc.FX_trans_BOM(valid, qMask), 2));
  OCI_annual(y)     = mean(sum(mc.FX_transl(valid,    qMask), 2));
end

% --- Stock-based PAM CC annual summary DISABLED --------------------------
% (three-way + LY decomposition no longer printed; flow-restricted BOM is
%  the canonical CC truth — see Section 3 below)

fprintf('\n=== PAM — Annual Results (mean over %d iterations, SEK) ===\n', nValid);
fprintf('%-6s %14s %14s %14s\n', ...
  'Year', 'TI (bonds)', 'TI (bonds+BOM)', 'OCI');
fprintf('%s\n', repmat('-', 1, 56));
for y = 1:nYears
  fprintf('%-6d %14.0f %14.0f %14.0f\n', ...
    uniqueYears(y), TI_annual(y), TI_BOM_annual(y), OCI_annual(y));
end
fprintf('%s\n', repmat('-', 1, 56));
fprintf('%-6s %14.0f %14.0f %14.0f\n', 'TOTAL', ...
  sum(TI_annual), sum(TI_BOM_annual), sum(OCI_annual));

% =========================================================================
% SIMULATION VALIDATION — Revenue, Gross Margin, Currency Exposure
% =========================================================================

% Folder for PDF output
figDir = fullfile(pwd, 'figures');
if ~exist(figDir, 'dir')
  [ok, msg] = mkdir(figDir);
  if ~ok, error('Could not create figures folder: %s', msg); end
end

% Dock all figures as tabs in a single MATLAB Figures container so they
% don't pop up as ~20 separate windows. The PDFs still save normally.
%
% NOTE: figure(N) re-uses the existing figure with handle N if one already
% exists, KEEPING its current WindowStyle (so an old undocked figure 10
% from a previous runMC call stays undocked even after we change the
% default). Closing all figures here makes the new default actually apply
% to every figure runMC creates below.
close all
set(0, 'DefaultFigureWindowStyle', 'docked');

% Plot colors (used throughout all figures)
cPAM   = [0.12 0.47 0.71];  % blue   — PAM bonds
cM1    = [0.89 0.10 0.11];  % red    — Method 1
cM2w   = [0.99 0.55 0.24];  % orange — M2 weekly
cM2m   = [0.20 0.63 0.17];  % green  — M2 monthly
cM2q   = [0.55 0.34 0.72];  % purple — M2 quarterly
cCCavg = [0.09 0.62 0.75];  % teal   — CC average
cCCcls = [0.55 0.34 0.72];  % purple — CC close

valValid = ~any(isnan(mc.actRevEUR), 2);
nValValid = sum(valValid);

% Load targets from simSummary (written by worker 1; same targets across all K)
ss_targets = [];
for wf_try = {'simulatedData', fullfile('simulatedData','worker_1'), ...
              fullfile('simulatedData','worker_2'), fullfile('simulatedData','worker_3')}
  try
    tmp_t = load(fullfile(wf_try{1}, 'simSummary'), 'simSummary');
    ss_targets = tmp_t.simSummary;
    break;
  catch
  end
end

if ~isempty(ss_targets) && nValValid > 0
  tgtRev   = ss_targets.targetRevenue / 1e6;   % MEUR
  tgtGM    = ss_targets.targetGMpct;
  curNames = ss_targets.curNames;
  tgtExp   = ss_targets.expPct;
  simYrs   = ss_targets.simYears;
  nYv      = length(simYrs);

  meanRev  = mean(mc.actRevEUR(valValid, 1:nYv), 1) / 1e6;
  stdRev   = std(mc.actRevEUR(valValid,  1:nYv), 0, 1) / 1e6;
  meanGM   = mean(mc.actGMpct(valValid,  1:nYv), 1);
  stdGM    = std(mc.actGMpct(valValid,   1:nYv), 0, 1);

  fprintf('\n=== Simulation Validation — Revenue & Gross Margin (mean ± std across %d iterations) ===\n', nValValid);
  fprintf('%-6s %10s %10s %8s %10s %8s %8s\n', 'Year', 'TgtRev(M)', 'MeanRev(M)', 'StdRev', 'TgtGM%', 'MeanGM%', 'StdGM%');
  fprintf('%s\n', repmat('-', 1, 72));
  for y = 1:nYv
    fprintf('%-6d %10.1f %10.1f %8.1f %10.1f %8.1f %8.1f\n', ...
      simYrs(y), tgtRev(y), meanRev(y), stdRev(y), tgtGM(y), meanGM(y), stdGM(y));
  end
  fprintf('%s\n', repmat('-', 1, 72));

  % Currency exposure table
  netExp3 = mc.netExpPct(valValid, 1:nYv, :);   % [nValValid x nYv x nCur]
  meanExp = squeeze(mean(mean(netExp3, 1), 2));  % [nCur x 1] mean over K and years
  stdExp  = squeeze(std(reshape(netExp3, nValValid*nYv, []), 0, 1)); % [nCur x 1]
  avgGM_v = mean(tgtGM);
  fprintf('\n=== Simulation Validation — Net Currency Exposure (mean ± std across K×years) ===\n');
  fprintf('%-6s %10s %10s %8s\n', 'Curr', 'Target%', 'Mean%', 'Std%');
  fprintf('%s\n', repmat('-', 1, 38));
  for c = 1:length(curNames)
    tgt_c = avgGM_v * tgtExp(c) / 100;
    fprintf('%-6s %10.2f %10.2f %8.2f\n', curNames{c}, tgt_c, meanExp(c), stdExp(c));
  end
  fprintf('%s\n', repmat('-', 1, 38));

  % --- Figure 29: Revenue and GM validation ---------------------------------
  fig = figure();
  subplot(2,1,1);
  hold on;
  fill([simYrs, fliplr(simYrs)], [meanRev-stdRev, fliplr(meanRev+stdRev)], ...
    cPAM, 'FaceAlpha', 0.2, 'EdgeColor', 'none', 'HandleVisibility', 'off');
  plot(simYrs, meanRev, '-o', 'Color', cPAM, 'LineWidth', 1.1, 'MarkerSize', 3, 'DisplayName', 'Simulated (mean±std)');
  plot(simYrs, tgtRev,  '--k', 'LineWidth', 0.9, 'DisplayName', 'Target');
  ylabel('Revenue (MEUR)'); legend('Location','Best'); grid on;
  title('Revenue: simulated vs target');

  subplot(2,1,2);
  hold on;
  fill([simYrs, fliplr(simYrs)], [meanGM-stdGM, fliplr(meanGM+stdGM)], ...
    cPAM, 'FaceAlpha', 0.2, 'EdgeColor', 'none', 'HandleVisibility', 'off');
  plot(simYrs, meanGM, '-o', 'Color', cPAM, 'LineWidth', 1.1, 'MarkerSize', 3, 'DisplayName', 'Simulated (mean±std)');
  plot(simYrs, tgtGM,  '--k', 'LineWidth', 0.9, 'DisplayName', 'Target');
  ylabel('Gross Margin (%)'); xlabel('Year'); legend('Location','Best'); grid on;
  title('Gross margin: simulated vs target');
  formatFig(fig, 16, 12);
  saveas(fig, fullfile(figDir, 'validation_rev_gm.pdf'));
end

% =========================================================================
% OUTPUT — Three sections: TI | Translation (OCI) | Constant Currency (CC)
% Each section: (1) actual values table  (2) error table
%               (3-6) four separate figures, saved as PDF
% =========================================================================


qx = 1:nPeriods;

% X-axis: full year for first and last, two-digit for the rest (e.g. 2007, 08, 09 ... 2025)
isNewYear  = [true; diff(qYears) ~= 0];
xTickLbls  = repmat({''}, 1, nPeriods);
newYearIdx = find(isNewYear);
for ii = 1:length(newYearIdx)
  yr = qYears(newYearIdx(ii));
  if yr == qYears(1) || yr == qYears(end)
    xTickLbls{newYearIdx(ii)} = num2str(yr);
  else
    xTickLbls{newYearIdx(ii)} = sprintf('%02d', mod(yr, 100));
  end
end

mu       = @(M) mean(M,1)/1e6;
printRow = @(label, A, B) printErrRow(label, A, B);
kdeplot  = @(ax, e, lbl, col) plotSilvermanKDE(ax, e, lbl, col);

% --- Extract quarterly matrices [nValid x nPeriods] ----------------------
qV = @(field) mc.(field)(valid,:);

PAM_TI_q     = qV('FX_trans');
PAM_TI_BOM_q = qV('FX_trans_BOM');
PAM_OCI_q    = qV('FX_transl');
M1_TI_q      = qV('M1_TI');    M1_OCI_q  = qV('M1_OCI');
M2w_TI_q     = qV('M2w_TI');   M2w_OCI_q = qV('M2w_OCI');
M2m_TI_q     = qV('M2m_TI');   M2m_OCI_q = qV('M2m_OCI');
M2q_TI_q     = qV('M2q_TI');   M2q_OCI_q = qV('M2q_OCI');
% fSnap_q      = qV('flowCC_snap_total');   % snap mode DISABLED
fBonds_q     = qV('flowCC_bonds_total');
fBOM_q       = qV('flowCC_BOM_total');
fBOMext_q    = qV('flowCC_BOMext_total');   % TI-BOM-like CC (bonds + extra BOM-phase)
M1_CC_q      = qV('M1_CC_TI')    + qV('M1_CC_OCI');
CC_avg_q     = qV('CC_avg_TI')   + qV('CC_avg_OCI');
CC_close_q   = qV('CC_close_TI') + qV('CC_close_OCI');

N_obs = nValid * nPeriods;

% =========================================================================
%  SECTION 1 — TRANSACTIONAL IMPACT (TI)
% =========================================================================
fprintf('\n');
fprintf('##########################################################################\n');
fprintf('##  SECTION 1: TRANSACTIONAL IMPACT (TI)                              ##\n');
fprintf('##########################################################################\n');

% --- 1a. Actual values table ----------------------------------------------
fprintf('\nActual mean values per quarter (SEK millions, mean over %d iterations)\n', nValid);
printActualTable( ...
  {'PAM bonds','PAM bonds+BOM','M1','M2 weekly','M2 monthly','M2 quarterly'}, ...
  {PAM_TI_q, PAM_TI_BOM_q, M1_TI_q, M2w_TI_q, M2m_TI_q, M2q_TI_q}, ...
  periodDates, nPeriods);

% --- 1b. Error table — PAM bonds benchmark --------------------------------
fprintf('\nError terms (quarterly obs) | Benchmark: PAM bonds\n');
fprintf('N = %d obs (%d iterations x %d quarters)\n', N_obs, nValid, nPeriods);
printHeader();
printRow('PAM bonds      vs  M1',           M1_TI_q,  PAM_TI_q);
printRow('PAM bonds      vs  M2 weekly',    M2w_TI_q, PAM_TI_q);
printRow('PAM bonds      vs  M2 monthly',   M2m_TI_q, PAM_TI_q);
printRow('PAM bonds      vs  M2 quarterly', M2q_TI_q, PAM_TI_q);
fprintf('%s\n', repmat('-',1,112));
fprintf('  Industry vs industry\n');
printRow('M1             vs  M2 weekly',    M1_TI_q, M2w_TI_q);
printRow('M1             vs  M2 monthly',   M1_TI_q, M2m_TI_q);
printRow('M1             vs  M2 quarterly', M1_TI_q, M2q_TI_q);

% --- 1c. Error table — PAM bonds+BOM benchmark ----------------------------
fprintf('\nError terms (quarterly obs) | Benchmark: PAM bonds+BOM\n');
fprintf('N = %d obs (%d iterations x %d quarters)\n', N_obs, nValid, nPeriods);
printHeader();
printRow('PAM bonds+BOM  vs  M1',           M1_TI_q,  PAM_TI_BOM_q);
printRow('PAM bonds+BOM  vs  M2 weekly',    M2w_TI_q, PAM_TI_BOM_q);
printRow('PAM bonds+BOM  vs  M2 monthly',   M2m_TI_q, PAM_TI_BOM_q);
printRow('PAM bonds+BOM  vs  M2 quarterly', M2q_TI_q, PAM_TI_BOM_q);

% PAM bonds error terms (method − benchmark, positive = industry overstates)
err_TI_M1  = (M1_TI_q  - PAM_TI_q) / 1e6;
err_TI_M2w = (M2w_TI_q - PAM_TI_q) / 1e6;
err_TI_M2m = (M2m_TI_q - PAM_TI_q) / 1e6;
err_TI_M2q = (M2q_TI_q - PAM_TI_q) / 1e6;
% PAM bonds+BOM error terms
err_BOM_TI_M1  = (M1_TI_q  - PAM_TI_BOM_q) / 1e6;
err_BOM_TI_M2w = (M2w_TI_q - PAM_TI_BOM_q) / 1e6;
err_BOM_TI_M2m = (M2m_TI_q - PAM_TI_BOM_q) / 1e6;
err_BOM_TI_M2q = (M2q_TI_q - PAM_TI_BOM_q) / 1e6;

% --- Figure 10: TI mean per quarter ---------------------------------------
fig = figure(10); clf; hold on;
plot(qx, mu(PAM_TI_q),     '-o',  'Color',cPAM,'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM bonds');
plot(qx, mu(PAM_TI_BOM_q), '--s', 'Color',cPAM,'LineWidth',0.9,'MarkerSize',3,'DisplayName','PAM bonds+BOM');
plot(qx, mu(M1_TI_q),      '-o',  'Color',cM1, 'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1');
plot(qx, mu(M2w_TI_q),     '-o',  'Color',cM2w,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 weekly');
plot(qx, mu(M2m_TI_q),     '-o',  'Color',cM2m,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 monthly');
plot(qx, mu(M2q_TI_q),     '-o',  'Color',cM2q,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 quarterly');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',qx,'XTickLabel',xTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('TI — mean per quarter'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_actual.pdf'));

% --- Figure 11: TI cumulative ---------------------------------------------
fig = figure(11); clf; hold on;
plot(qx, cumsum(mu(PAM_TI_q)),     '-o',  'Color',cPAM,'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM bonds');
plot(qx, cumsum(mu(PAM_TI_BOM_q)), '--s', 'Color',cPAM,'LineWidth',0.9,'MarkerSize',3,'DisplayName','PAM bonds+BOM');
plot(qx, cumsum(mu(M1_TI_q)),      '-o',  'Color',cM1, 'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1');
plot(qx, cumsum(mu(M2w_TI_q)),     '-o',  'Color',cM2w,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 weekly');
plot(qx, cumsum(mu(M2m_TI_q)),     '-o',  'Color',cM2m,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 monthly');
plot(qx, cumsum(mu(M2q_TI_q)),     '-o',  'Color',cM2q,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 quarterly');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',qx,'XTickLabel',xTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('TI — cumulative'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_actual_cum.pdf'));

% --- Figure 12: TI error boxplot ------------------------------------------
fig = figure(12); clf;
boxplot([err_TI_M1(:),  err_TI_M2w(:),  err_TI_M2m(:),  err_TI_M2q(:), ...
         err_BOM_TI_M1(:), err_BOM_TI_M2w(:), err_BOM_TI_M2m(:), err_BOM_TI_M2q(:)], ...
  'Labels', {'bonds-M1',    'bonds-M2w',    'bonds-M2m',    'bonds-M2q', ...
              'bonds+BOM-M1','bonds+BOM-M2w','bonds+BOM-M2m','bonds+BOM-M2q'});
yline(0,'k--','HandleVisibility','off'); ylabel('SEK million'); title('TI — error distributions');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_errors_box.pdf'));

% --- Figure 13: TI error KDE — PAM bonds benchmark ------------------------
fig = figure(13); clf; hold on;
kdeplot(gca, err_TI_M1(:),  'PAM bonds vs M1',          cM1);
kdeplot(gca, err_TI_M2w(:), 'PAM bonds vs M2 weekly',   cM2w);
kdeplot(gca, err_TI_M2m(:), 'PAM bonds vs M2 monthly',  cM2m);
kdeplot(gca, err_TI_M2q(:), 'PAM bonds vs M2 quarterly',cM2q);
xline(0,'k--','HandleVisibility','off'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on; title('TI — error densities (PAM bonds benchmark)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_errors_kde_bonds.pdf'));

% --- Figure 14: TI error KDE — PAM bonds+BOM benchmark -------------------
fig = figure(14); clf; hold on;
kdeplot(gca, err_BOM_TI_M1(:),  'PAM bonds+BOM vs M1',          cM1);
kdeplot(gca, err_BOM_TI_M2w(:), 'PAM bonds+BOM vs M2 weekly',   cM2w);
kdeplot(gca, err_BOM_TI_M2m(:), 'PAM bonds+BOM vs M2 monthly',  cM2m);
kdeplot(gca, err_BOM_TI_M2q(:), 'PAM bonds+BOM vs M2 quarterly',cM2q);
xline(0,'k--','HandleVisibility','off'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on; title('TI — error densities (PAM bonds+BOM benchmark)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_errors_kde_bom.pdf'));

% =========================================================================
%  SECTION 2 — TRANSLATION / OCI
% =========================================================================
fprintf('\n');
fprintf('##########################################################################\n');
fprintf('##  SECTION 2: TRANSLATION / OCI                                      ##\n');
fprintf('##########################################################################\n');

% --- 2a. Actual values table ----------------------------------------------
fprintf('\nActual mean values per quarter (SEK millions, mean over %d iterations)\n', nValid);
printActualTable( ...
  {'PAM','M1','M2 weekly','M2 monthly','M2 quarterly'}, ...
  {PAM_OCI_q, M1_OCI_q, M2w_OCI_q, M2m_OCI_q, M2q_OCI_q}, ...
  periodDates, nPeriods);

% --- 2b. Error table ------------------------------------------------------
fprintf('\nError terms (quarterly obs) | Benchmark: PAM Translation\n');
fprintf('N = %d obs (%d iterations x %d quarters)\n', N_obs, nValid, nPeriods);
printHeader();
printRow('PAM transl  vs  M1 OCI',       M1_OCI_q,  PAM_OCI_q);
printRow('PAM transl  vs  M2 weekly',    M2w_OCI_q, PAM_OCI_q);
printRow('PAM transl  vs  M2 monthly',   M2m_OCI_q, PAM_OCI_q);
printRow('PAM transl  vs  M2 quarterly', M2q_OCI_q, PAM_OCI_q);
fprintf('%s\n', repmat('-',1,112));
fprintf('  Industry vs industry\n');
printRow('M1 OCI      vs  M2 weekly',    M1_OCI_q, M2w_OCI_q);
printRow('M1 OCI      vs  M2 monthly',   M1_OCI_q, M2m_OCI_q);
printRow('M1 OCI      vs  M2 quarterly', M1_OCI_q, M2q_OCI_q);

err_OCI_M1  = (M1_OCI_q  - PAM_OCI_q) / 1e6;
err_OCI_M2w = (M2w_OCI_q - PAM_OCI_q) / 1e6;
err_OCI_M2m = (M2m_OCI_q - PAM_OCI_q) / 1e6;
err_OCI_M2q = (M2q_OCI_q - PAM_OCI_q) / 1e6;

% --- Figure 15: OCI mean per quarter --------------------------------------
fig = figure(15); clf; hold on;
plot(qx, mu(PAM_OCI_q),  '-o', 'Color',cPAM,'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM');
plot(qx, mu(M1_OCI_q),   '-o', 'Color',cM1, 'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1');
plot(qx, mu(M2w_OCI_q),  '-o', 'Color',cM2w,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 weekly');
plot(qx, mu(M2m_OCI_q),  '-o', 'Color',cM2m,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 monthly');
plot(qx, mu(M2q_OCI_q),  '-o', 'Color',cM2q,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 quarterly');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',qx,'XTickLabel',xTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('OCI — mean per quarter'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'OCI_actual.pdf'));

% --- Figure 16: OCI cumulative --------------------------------------------
fig = figure(16); clf; hold on;
plot(qx, cumsum(mu(PAM_OCI_q)),  '-o', 'Color',cPAM,'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM');
plot(qx, cumsum(mu(M1_OCI_q)),   '-o', 'Color',cM1, 'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1');
plot(qx, cumsum(mu(M2w_OCI_q)),  '-o', 'Color',cM2w,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 weekly');
plot(qx, cumsum(mu(M2m_OCI_q)),  '-o', 'Color',cM2m,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 monthly');
plot(qx, cumsum(mu(M2q_OCI_q)),  '-o', 'Color',cM2q,'LineWidth',1.3,'MarkerSize',3,'DisplayName','M2 quarterly');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',qx,'XTickLabel',xTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('OCI — cumulative'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'OCI_actual_cum.pdf'));

% --- Figure 17: OCI error boxplot -----------------------------------------
fig = figure(17); clf;
boxplot([err_OCI_M1(:), err_OCI_M2w(:), err_OCI_M2m(:), err_OCI_M2q(:)], ...
  'Labels', {'PAM-M1','PAM-M2w','PAM-M2m','PAM-M2q'});
yline(0,'k--','HandleVisibility','off'); ylabel('SEK million'); title('OCI — error distributions');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'OCI_errors_box.pdf'));

% --- Figure 18: OCI error KDE ---------------------------------------------
fig = figure(18); clf; hold on;
kdeplot(gca, err_OCI_M1(:),  'PAM vs M1',          cM1);
kdeplot(gca, err_OCI_M2w(:), 'PAM vs M2 weekly',   cM2w);
kdeplot(gca, err_OCI_M2m(:), 'PAM vs M2 monthly',  cM2m);
kdeplot(gca, err_OCI_M2q(:), 'PAM vs M2 quarterly',cM2q);
xline(0,'k--','HandleVisibility','off'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on; title('OCI — error densities');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'OCI_errors_kde.pdf'));

% =========================================================================
%  SECTION 3 — CONSTANT CURRENCY (CC)
%  CC requires prior-year average FX rates; CNY data begins Jan 2007 so
%  2007 quarters have no valid comparison rates. All CC output starts 2008.
% =========================================================================
fprintf('\n');
fprintf('##########################################################################\n');
fprintf('##  SECTION 3: CONSTANT CURRENCY (CC)                                 ##\n');
fprintf('##########################################################################\n');

% Restrict CC to 2008+ (2007 CC = 0 because CNY yield curve data begins Jan 2007)
ccMask  = (qYears >= 2008);
ccNP    = sum(ccMask);
ccPD    = [0; periodDates(find(ccMask)+1)];  % end-boundaries for printActualTable

% X-axis labels for CC figures (2008+)
ccYears = qYears(ccMask);
ccIsNewYear  = [true; diff(ccYears) ~= 0];
ccXTickLbls  = repmat({''}, 1, ccNP);
ccNewYearIdx = find(ccIsNewYear);
for ii = 1:length(ccNewYearIdx)
  yr = ccYears(ccNewYearIdx(ii));
  if yr == ccYears(1) || yr == ccYears(end)
    ccXTickLbls{ccNewYearIdx(ii)} = num2str(yr);
  else
    ccXTickLbls{ccNewYearIdx(ii)} = sprintf('%02d', mod(yr, 100));
  end
end
ccQx = 1:ccNP;

% Filtered CC matrices [nValid x ccNP]
fBonds_cc   = fBonds_q(:, ccMask);
fBOM_cc     = fBOM_q(:, ccMask);
fBOMext_cc  = fBOMext_q(:, ccMask);   % TI-BOM-like CC (bonds + extra BOM-phase)
M1_CC_cc    = M1_CC_q(:, ccMask);
CC_avg_cc   = CC_avg_q(:, ccMask);
CC_close_cc = CC_close_q(:, ccMask);
N_obs_cc    = nValid * ccNP;

% --- 3a. Actual values table ----------------------------------------------
fprintf('\nActual mean values per quarter (SEK millions, mean over %d iterations)\n', nValid);
fprintf('(2008 onwards; 2007 excluded — no prior-year CNY rates available)\n');
printActualTable( ...
  {'PAM bonds','PAM BOM','PAM BOMext','M1 CC','CC avg','CC close'}, ...
  {fBonds_cc, fBOM_cc, fBOMext_cc, M1_CC_cc, CC_avg_cc, CC_close_cc}, ...
  ccPD, ccNP);

% --- 3b. Error table — PAM bonds (flow) benchmark ------------------------
fprintf('\nError terms (quarterly obs) | Benchmark: PAM bonds (flow)\n');
fprintf('N = %d obs (%d iterations x %d quarters, 2008+)\n', N_obs_cc, nValid, ccNP);
printHeader();
printRow('PAM bonds      vs  M1 CC',    M1_CC_cc,  fBonds_cc);
printRow('PAM bonds      vs  CC avg',   CC_avg_cc, fBonds_cc);
printRow('PAM bonds      vs  CC close', CC_close_cc, fBonds_cc);
fprintf('%s\n', repmat('-',1,112));
fprintf('  Industry CC vs industry CC\n');
printRow('M1 CC          vs  CC avg',   M1_CC_cc,  CC_avg_cc);
printRow('M1 CC          vs  CC close', M1_CC_cc,  CC_close_cc);
printRow('CC avg         vs  CC close', CC_avg_cc, CC_close_cc);

% --- 3c. Error table — PAM BOM (flow, conventional) benchmark ------------
fprintf('\nError terms (quarterly obs) | Benchmark: PAM BOM (flow, redistribution-only)\n');
fprintf('N = %d obs (%d iterations x %d quarters, 2008+)\n', N_obs_cc, nValid, ccNP);
printHeader();
printRow('PAM BOM        vs  M1 CC',    M1_CC_cc,  fBOM_cc);
printRow('PAM BOM        vs  CC avg',   CC_avg_cc, fBOM_cc);
printRow('PAM BOM        vs  CC close', CC_close_cc, fBOM_cc);

% --- 3d. Error table — PAM BOMext (flow, TI-BOM-like) benchmark ----------
% BOMext cumulative = bonds + (per-event F(t_rec) - F(t_ord)) summed,
% mirroring TI BOM's structure. Industry CC vs BOMext shows the "true"
% economic CC gap under the holistic deviation-over-commitment-period
% interpretation.
fprintf('\nError terms (quarterly obs) | Benchmark: PAM BOMext (flow, TI-BOM-like)\n');
fprintf('N = %d obs (%d iterations x %d quarters, 2008+)\n', N_obs_cc, nValid, ccNP);
printHeader();
printRow('PAM BOMext     vs  M1 CC',    M1_CC_cc,    fBOMext_cc);
printRow('PAM BOMext     vs  CC avg',   CC_avg_cc,   fBOMext_cc);
printRow('PAM BOMext     vs  CC close', CC_close_cc, fBOMext_cc);
fprintf('%s\n', repmat('-',1,112));
fprintf('  PAM mode comparisons\n');
printRow('PAM BOMext     vs  PAM bonds', fBOMext_cc, fBonds_cc);  % size of BOM-phase extension
printRow('PAM BOMext     vs  PAM BOM',   fBOMext_cc, fBOM_cc);

err_BOM_M1    = (M1_CC_cc    - fBOM_cc)   / 1e6;
err_BOM_avg   = (CC_avg_cc   - fBOM_cc)   / 1e6;
err_BOM_close = (CC_close_cc - fBOM_cc)   / 1e6;
err_bonds_M1  = (M1_CC_cc    - fBonds_cc) / 1e6;
err_bonds_avg = (CC_avg_cc   - fBonds_cc) / 1e6;
err_bonds_close = (CC_close_cc - fBonds_cc) / 1e6;
err_BOMext_M1    = (M1_CC_cc    - fBOMext_cc) / 1e6;
err_BOMext_avg   = (CC_avg_cc   - fBOMext_cc) / 1e6;
err_BOMext_close = (CC_close_cc - fBOMext_cc) / 1e6;

% --- Figure 19: CC mean per quarter (2008+) --------------------------------
fig = figure(19); clf; hold on;
plot(ccQx, mu(fBOM_cc),     '-o',  'Color',cPAM,  'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM BOM');
plot(ccQx, mu(fBonds_cc),   '--s', 'Color',cPAM,  'LineWidth',0.9,'MarkerSize',3,'DisplayName','PAM bonds');
plot(ccQx, mu(fBOMext_cc),  ':d',  'Color',cPAM,  'LineWidth',1.0,'MarkerSize',3,'DisplayName','PAM BOMext');
plot(ccQx, mu(M1_CC_cc),    '-o',  'Color',cM1,   'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1 CC');
plot(ccQx, mu(CC_avg_cc),   '-o',  'Color',cCCavg,'LineWidth',1.3,'MarkerSize',3,'DisplayName','CC avg');
plot(ccQx, mu(CC_close_cc), '-o',  'Color',cCCcls,'LineWidth',1.3,'MarkerSize',3,'DisplayName','CC close');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',ccQx,'XTickLabel',ccXTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('CC — mean per quarter'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_actual.pdf'));

% --- Figure 20: CC cumulative (2008+) -------------------------------------
fig = figure(20); clf; hold on;
plot(ccQx, cumsum(mu(fBOM_cc)),     '-o',  'Color',cPAM,  'LineWidth',1.3,'MarkerSize',3,'DisplayName','PAM BOM');
plot(ccQx, cumsum(mu(fBonds_cc)),   '--s', 'Color',cPAM,  'LineWidth',0.9,'MarkerSize',3,'DisplayName','PAM bonds');
plot(ccQx, cumsum(mu(fBOMext_cc)),  ':d',  'Color',cPAM,  'LineWidth',1.0,'MarkerSize',3,'DisplayName','PAM BOMext');
plot(ccQx, cumsum(mu(M1_CC_cc)),    '-o',  'Color',cM1,   'LineWidth',1.3,'MarkerSize',3,'DisplayName','M1 CC');
plot(ccQx, cumsum(mu(CC_avg_cc)),   '-o',  'Color',cCCavg,'LineWidth',1.3,'MarkerSize',3,'DisplayName','CC avg');
plot(ccQx, cumsum(mu(CC_close_cc)), '-o',  'Color',cCCcls,'LineWidth',1.3,'MarkerSize',3,'DisplayName','CC close');
yline(0,'k--','LineWidth',0.8,'HandleVisibility','off');
set(gca,'XTick',ccQx,'XTickLabel',ccXTickLbls,'XTickLabelRotation',0);
ylabel('SEK million'); title('CC — cumulative'); legend('Location','Best'); grid on;
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_actual_cum.pdf'));

% --- Figure 21: CC error boxplot ------------------------------------------
fig = figure(21); clf;
boxplot([err_BOM_M1(:),   err_BOM_avg(:),   err_BOM_close(:), ...
         err_bonds_M1(:), err_bonds_avg(:), err_bonds_close(:)], ...
  'Labels', {'BOM-M1','BOM-avg','BOM-close','bonds-M1','bonds-avg','bonds-close'});
yline(0,'k--','HandleVisibility','off'); ylabel('SEK million'); title('CC — error distributions');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_errors_box.pdf'));

% --- Figure 22: CC error KDE — PAM BOM benchmark -------------------------
fig = figure(22); clf; hold on;
kdeplot(gca, err_BOM_M1(:),    'PAM BOM vs M1 CC',    cM1);
kdeplot(gca, err_BOM_avg(:),   'PAM BOM vs CC avg',   cCCavg);
kdeplot(gca, err_BOM_close(:), 'PAM BOM vs CC close', cCCcls);
xline(0,'k--','HandleVisibility','off'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on; title('CC — error densities (PAM BOM benchmark)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_errors_kde_bom.pdf'));

% --- Figure 23: CC error KDE — PAM bonds benchmark -----------------------
fig = figure(23); clf; hold on;
kdeplot(gca, err_bonds_M1(:),    'PAM bonds vs M1 CC',    cM1);
kdeplot(gca, err_bonds_avg(:),   'PAM bonds vs CC avg',   cCCavg);
kdeplot(gca, err_bonds_close(:), 'PAM bonds vs CC close', cCCcls);
xline(0,'k--','HandleVisibility','off'); xlabel('Error (SEK million)'); ylabel('Density');
legend('Location','Best'); grid on; title('CC — error densities (PAM bonds benchmark)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_errors_kde_bonds.pdf'));

% =========================================================================
% FIGURES 24-28: Per-quarter std histograms
% For each error series [K x nPeriods], compute std across K for each quarter
% → nPeriods values. Histogram shows how simulation noise varies over time.
% =========================================================================

% --- Figure 24: TI per-quarter std — PAM bonds benchmark ------------------
fig = figure(); hold on;
stdHist(gca, err_TI_M1,  'PAM bonds vs M1',          cM1);
stdHist(gca, err_TI_M2w, 'PAM bonds vs M2 weekly',   cM2w);
stdHist(gca, err_TI_M2m, 'PAM bonds vs M2 monthly',  cM2m);
stdHist(gca, err_TI_M2q, 'PAM bonds vs M2 quarterly',cM2q);
xlabel('Per-quarter Std (SEK million)'); ylabel('Count');
legend('Location','Best'); grid on; title('TI — quarterly std (PAM bonds)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_std_hist_bonds.pdf'));

% --- Figure 25: TI per-quarter std — PAM bonds+BOM benchmark --------------
fig = figure(); hold on;
stdHist(gca, err_BOM_TI_M1,  'PAM bonds+BOM vs M1',          cM1);
stdHist(gca, err_BOM_TI_M2w, 'PAM bonds+BOM vs M2 weekly',   cM2w);
stdHist(gca, err_BOM_TI_M2m, 'PAM bonds+BOM vs M2 monthly',  cM2m);
stdHist(gca, err_BOM_TI_M2q, 'PAM bonds+BOM vs M2 quarterly',cM2q);
xlabel('Per-quarter Std (SEK million)'); ylabel('Count');
legend('Location','Best'); grid on; title('TI — quarterly std (PAM bonds+BOM)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'TI_std_hist_bom.pdf'));

% --- Figure 26: OCI per-quarter std ----------------------------------------
fig = figure(); hold on;
stdHist(gca, err_OCI_M1,  'PAM vs M1',          cM1);
stdHist(gca, err_OCI_M2w, 'PAM vs M2 weekly',   cM2w);
stdHist(gca, err_OCI_M2m, 'PAM vs M2 monthly',  cM2m);
stdHist(gca, err_OCI_M2q, 'PAM vs M2 quarterly',cM2q);
xlabel('Per-quarter Std (SEK million)'); ylabel('Count');
legend('Location','Best'); grid on; title('OCI — quarterly std');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'OCI_std_hist.pdf'));

% --- Figure 27: CC per-quarter std — PAM BOM benchmark --------------------
fig = figure(); hold on;
stdHist(gca, err_BOM_M1,    'PAM BOM vs M1 CC',    cM1);
stdHist(gca, err_BOM_avg,   'PAM BOM vs CC avg',   cCCavg);
stdHist(gca, err_BOM_close, 'PAM BOM vs CC close', cCCcls);
xlabel('Per-quarter Std (SEK million)'); ylabel('Count');
legend('Location','Best'); grid on; title('CC — quarterly std (PAM BOM)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_std_hist_bom.pdf'));

% --- Figure 28: CC per-quarter std — PAM bonds benchmark ------------------
fig = figure(); hold on;
stdHist(gca, err_bonds_M1,    'PAM bonds vs M1 CC',    cM1);
stdHist(gca, err_bonds_avg,   'PAM bonds vs CC avg',   cCCavg);
stdHist(gca, err_bonds_close, 'PAM bonds vs CC close', cCCcls);
xlabel('Per-quarter Std (SEK million)'); ylabel('Count');
legend('Location','Best'); grid on; title('CC — quarterly std (PAM bonds)');
formatFig(fig, 16, 8);
saveas(fig, fullfile(figDir,'CC_std_hist_bonds.pdf'));

% =========================================================================
% SENSITIVITY — Timing-parameter sweep
%   Set doSensitivity = true before running to execute runSensitivity.m
%   after the main MC completes.
% =========================================================================
if exist('doSensitivity', 'var') && doSensitivity
  clear results   % runMC uses results as cell array; runSensitivity needs it as struct
  runSensitivity
end

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================
function printHeader()
  fprintf('%s\n', repmat('=',1,112));
  fprintf('%-34s %12s %12s   %-27s  %12s\n', ...
    'Method pair', 'ME (SEK)', 'Std (SEK)', '95% CI (SEK)', 'RMSE (SEK)');
  fprintf('%s\n', repmat('-',1,112));
end

function printErrRow(label, A, B)
% A, B are [K x nPeriods] matrices. All stats computed over all K*nPeriods obs.
  e     = A - B;
  n     = numel(e);
  me    = mean(e(:));
  s     = std(e(:));
  rmse  = sqrt(mean(e(:).^2));
  ci_hw = 1.96 * s / sqrt(n);
  fprintf('%-34s %12.0f %12.0f   [%12.0f, %12.0f]  %12.0f\n', ...
    label, me, s, me-ci_hw, me+ci_hw, rmse);
end

function plotSilvermanKDE(ax, e, lbl, col)
  N  = numel(e);
  s  = std(e);
  h  = 0.9 * min(s, iqr(e)/1.34) * N^(-1/5);
  [f, xi] = ksdensity(e, 'Bandwidth', h);
  plot(ax, xi, f, 'Color', col, 'LineWidth', 1.3, 'DisplayName', lbl);
end

function saveCheckpoint(fname, r) %#ok<INUSD>
% Wrapper so save can be called from inside parfor (direct save is not allowed).
  save(fname, 'r');
end

function stdHist(ax, e, lbl, col)
% Plot histogram of per-quarter std (std across K for each quarter).
% Uses stairs() directly (Line object) so legend shows a colored line,
% not the near-invisible outlined patch from histogram DisplayStyle='stairs'.
  s = std(e, 0, 1);
  [counts, edges] = histcounts(s, 10);
  % Append final edge at zero so the last bar closes properly
  stairs(ax, [edges(1:end-1), edges(end)], [counts, 0], ...
    'Color', col, 'LineWidth', 1.5, 'DisplayName', lbl);
end

function formatFig(fig, w, h)
% Set figure to exact physical size and apply consistent typography to all axes.
% Uses -depth 1 to restrict to direct children of the figure, avoiding
% hidden internal axes created by boxplot (which would corrupt outlier colors).
%
% Force-dock the figure here so every figure in runMC ends up as a tab in
% the MATLAB Figures container regardless of whether the WindowStyle
% default was honored at creation. Position is only set if undocked
% (MATLAB warns when trying to set Position on a docked figure).
  set(fig, 'WindowStyle', 'docked');
  set(fig, 'PaperUnits','centimeters', 'PaperSize',[w h], ...
           'PaperPosition',[0 0 w h], 'PaperPositionMode','manual');
  allAx = findobj(fig, '-depth', 1, 'Type', 'axes');
  for i = 1:length(allAx)
    ax = allAx(i);
    ax.FontSize         = 9;
    ax.Title.FontSize   = 11;
    ax.Title.FontWeight = 'bold';
    ax.XLabel.FontSize  = 10;
    ax.YLabel.FontSize  = 10;
    if ~isempty(ax.Legend)
      ax.Legend.FontSize = 9;
    end
  end
end

function printActualTable(methodNames, matrices, periodDates, nPeriods)
% Mean values per quarter for each method, in SEK millions.
  nc   = length(methodNames);
  colW = 13;
  fprintf('%-12s', 'Quarter');
  for m = 1:nc
    fprintf('%*s', colW, methodNames{m});
  end
  fprintf('\n%s\n', repmat('-', 1, 12 + colW*nc));
  for p = 1:nPeriods
    fprintf('%-12s', datestr(periodDates(p+1), 'yyyy-Qq'));
    for m = 1:nc
      fprintf('%*s', colW, sprintf('%.1f', mean(matrices{m}(:,p))/1e6));
    end
    fprintf('\n');
  end
  fprintf('%s\n', repmat('-', 1, 12 + colW*nc));
  fprintf('%-12s', 'TOTAL');
  for m = 1:nc
    fprintf('%*s', colW, sprintf('%.1f', sum(mean(matrices{m},1))/1e6));
  end
  fprintf('\n');
end
