% runSensitivity  Timing-parameter sensitivity sweep
%
% Varies each of 4 timing parameters from Table 4.7 independently while the
% others are held at baseline:
%   procLead  - procurement lead time (order -> delivery)
%   mfg       - manufacturing duration
%   custPay   - customer payment delay
%   suppPay   - supplier payment delay
%
% For scaling factor s in {0, 0.25, 0.5, 0.75, 1}, the swept mean is
%   mu^(s)    = (1 - s) * mu_baseline
%   sigma^(s) = (1 - s) * sigma_baseline    (CV preserved across sweep)
% so s=0 is the baseline and s=1 collapses the parameter to zero.
%
% At each (param, s) cell, runs K MC iterations and computes RMSE / ME
% of each industry method against the relevant PAM benchmark:
%   TI  : PAM bonds (FX_trans)          vs M1, M2 weekly/monthly/quarterly
%   OCI : PAM translation (FX_transl)   vs M1 OCI, M2 OCI variants
%   CC  : PAM BOM flow CC               vs M1 CC, CC avg, CC close, PAM bonds
%
% Outputs:
%   sensitivity_results.mat  - full grid of mc metrics
%   sensitivity_<param>.fig  - RMSE vs s, one line per method, 3 subplots (TI/OCI/CC)
%
% Usage:
%   runSensitivity                 % default K = 50
%   K = 100; runSensitivity        % override K
if ~exist('K', 'var'), K = 1; end

% -------------------------------------------------------------------------
% DISTRIBUTED RUN — optional, leave commented out to run all seeds locally
% -------------------------------------------------------------------------
% To run a single machine over ALL seeds 1:K for every (param, scaling)
% cell (default), leave the line below commented out. To split the
% workload across multiple machines, uncomment and set `seeds` to the
% seed range this machine should handle (applied across all 20 cells).
% Example for two machines splitting K=1000:
%
%   Machine A:  seeds = 1:500;        % first half  -> 20 * 500 = 10000 tasks
%   Machine B:  seeds = 501:1000;     % second half -> 20 * 500 = 10000 tasks
%
% Both machines must write checkpoints into the same
% `sensitivity_checkpoints/` folder (network share, OneDrive, etc.) or
% have their folders merged before final aggregation. Filenames embed the
% seed number, so there is no collision between machines.
%
% The in-script RMSE/ME tables at the end only count THIS machine's seeds.
% To get the combined statistics across both halves, copy/merge all
% checkpoint .mat files into one folder and re-run runSensitivity with
% `seeds` UNSET (use `clear seeds` first). Every task will skip via the
% existing "checkpoint exists" path, then aggregation runs over 1:K.
%
% seeds = 1:500;    %  <-- uncomment and edit this line to split work
% -------------------------------------------------------------------------
if ~exist('seeds', 'var'), seeds = 1:K; end

% =========================================================================
% BASELINE TIMING  (must mirror createMatFilesSim defaults)
% =========================================================================
baseline.procLeadMean = 45;  baseline.procLeadStd = 10;
baseline.mfgMean      = 30;  baseline.mfgStd      =  5;
baseline.custPayMean  = 45;  baseline.custPayStd  = 15;
baseline.suppPayMean  = 60;  baseline.suppPayStd  = 15;

% Parameter sweep table:  key | display label | mean-field | std-field
paramSweeps = {
  'procLead',  'Procurement lead time',  'procLeadMean', 'procLeadStd';
  'mfg',       'Manufacturing time',     'mfgMean',      'mfgStd';
  'custPay',   'Customer payment delay', 'custPayMean',  'custPayStd';
  'suppPay',   'Supplier payment delay', 'suppPayMean',  'suppPayStd';
};
scalings = [0, 0.25, 0.5, 0.75, 1];
nParams  = size(paramSweeps, 1);
nScales  = length(scalings);

% =========================================================================
% SETTINGS  (mirror runMC)
% =========================================================================
settings.dataFolder         = 'simulatedData';
settings.bomPricing         = 'DeterministicCashFlows';
settings.curFunctional      = 'EUR';
settings.startDate          = datenum(2006,1,1);
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
settings.currencies         = {'AUD','CAD','CNY','EUR','SEK','USD','ZAR'};

addpath(fullfile('IndustryMethods'));
addpath(fullfile('IndustryMethods', 'Method1'));
addpath(fullfile('IndustryMethods', 'Method2'));

% =========================================================================
% LOAD MARKET DATA + SANDVIK ARRAYS  (once)
% =========================================================================
if ~exist('dm', 'var') || ~isfield(dm,'cName') || ~isfield(dm,'dates')
  fprintf('Loading market data...\n');
  dm = createDataMarket('reutersZero', settings);
  fprintf('Market data: %d dates, %d currencies\n\n', length(dm.dates), length(dm.cName));
end

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
fprintf('Sandvik data pre-loaded.\n');

% Checkpoint folder — each (param, scaling, seed) cell saved to disk so runs
% survive interruption (mirrors runMC's mc_checkpoints pattern).
ckptDir = 'sensitivity_checkpoints';
if ~exist(ckptDir, 'dir'), mkdir(ckptDir); end

% =========================================================================
% QUARTERLY PERIODS
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;
quarterIdx  = cell(nPeriods, 1);
for p = 1:nPeriods
  quarterIdx{p} = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
end

% =========================================================================
% PRE-ALLOCATE RESULTS  [nParams x nScales] per metric
% =========================================================================
results.K           = K;
results.scalings    = scalings;
results.paramKeys   = paramSweeps(:,1);
results.paramLabels = paramSweeps(:,2);
results.baseline    = baseline;

methodsTI       = {'M1','M2w','M2m','M2q'};
methodsOCI      = {'M1','M2w','M2m','M2q'};
methodsCC       = {'M1_CC','CC_avg','CC_close','PAM_bonds'};   % vs flowCC_BOM_total benchmark
methodsCC_bonds = {'M1_CC','CC_avg','CC_close'};               % vs flowCC_bonds_total benchmark
                                                               % (PAM_bonds would be the benchmark itself)

for m = methodsTI
  % vs PAM FX_trans (bonds-only, monetary-item TI)
  results.rmse_TI.(m{1})     = nan(nParams, nScales);
  results.me_TI.(m{1})       = nan(nParams, nScales);
  % vs PAM FX_trans_BOM (bonds + BOM phase, full economic TI exposure)
  results.rmse_TI_BOM.(m{1}) = nan(nParams, nScales);
  results.me_TI_BOM.(m{1})   = nan(nParams, nScales);
end
for m = methodsOCI
  results.rmse_OCI.(m{1}) = nan(nParams, nScales);
  results.me_OCI.(m{1})   = nan(nParams, nScales);
end
for m = methodsCC
  results.rmse_CC.(m{1}) = nan(nParams, nScales);
  results.me_CC.(m{1})   = nan(nParams, nScales);
end
for m = methodsCC_bonds
  results.rmse_CC_bonds.(m{1}) = nan(nParams, nScales);
  results.me_CC_bonds.(m{1})   = nan(nParams, nScales);
end

% =========================================================================
% MAIN SWEEP — flat task list parallelised across (param, scaling, seed)
% so adding workers helps even at small K. The previous design only
% parallelised the inner K loop and ran the 20 (param,scaling) cells
% sequentially, which at K=1 left 19/20 workers idle and made the sweep
% ~20x slower than necessary. The flat parfor produces identical results.
% =========================================================================
totalTasks = nParams * nScales * K;

% Build flat task list. Each task carries everything the worker needs.
tasks = cell(totalTasks, 1);
t_ = 0;
for pi_ = 1:nParams
  paramKey_  = paramSweeps{pi_, 1};
  meanField_ = paramSweeps{pi_, 3};
  stdField_  = paramSweeps{pi_, 4};
  for si_ = 1:nScales
    s_ = scalings(si_);
    to_ = baseline;
    to_.(meanField_) = (1 - s_) * baseline.(meanField_);
    to_.(stdField_)  = (1 - s_) * baseline.(stdField_);
    % Override createMatFilesSim's realism floors (procLead>=5, mfg>=1,
    % custPay>=7, suppPay>=1) so that s=1 actually drives windows toward
    % zero instead of bottoming out at the floor. Floor of 1 day is the
    % smallest meaningful value (events still need distinct calendar days
    % for buildPA's date indexing).
    to_.procLeadMin = 1;
    to_.mfgMin      = 1;
    to_.custPayMin  = 1;
    to_.suppPayMin  = 1;
    for k_ = 1:K
      t_ = t_ + 1;
      tasks{t_} = struct( ...
        'pi',             pi_, ...
        'si',             si_, ...
        'k',              k_, ...
        'paramKey',       paramKey_, ...
        's',              s_, ...
        'timingOverride', to_, ...
        'ckptFile',       fullfile(ckptDir, sprintf('%s_s%d_seed_%04d.mat', ...
                                                    paramKey_, si_, k_)));
    end
  end
end

% Build the list of task indices this machine handles. If `seeds` covers
% all of 1:K, this is just 1:totalTasks. Otherwise it filters to the
% (param,scaling) x seeds subset — same skip pattern as runMC.
runIdx = zeros(0, 1);
for t_ = 1:totalTasks
  if any(tasks{t_}.k == seeds), runIdx(end+1, 1) = t_; end %#ok<SAGROW>
end
nRun = length(runIdx);

% Count already-completed tasks (for resume reporting). Scoped to THIS
% machine's runIdx so the message reflects this machine's progress.
nDone = 0;
for ii_ = 1:nRun
  if exist(tasks{runIdx(ii_)}.ckptFile, 'file'), nDone = nDone + 1; end
end
if nDone > 0
  fprintf('\nResuming: %d/%d iterations already done (found in %s)\n', ...
    nDone, nRun, ckptDir);
end

if isequal(seeds, 1:K)
  fprintf('\nSensitivity sweep: K=%d, %d params x %d scalings = %d cells, %d total iters\n\n', ...
    K, nParams, nScales, nParams*nScales, totalTasks);
else
  fprintf(['\nSensitivity sweep: K=%d total, this machine runs seeds %d:%d ' ...
           '(%d per cell), %d params x %d scalings = %d cells, %d iters here\n\n'], ...
    K, min(seeds), max(seeds), length(seeds), nParams, nScales, ...
    nParams*nScales, nRun);
end
tStart = tic;

% Progress counter via DataQueue (parfor-safe; skipped if no PCT).
% Prints one line per task completion (out-of-order is expected).
try
  dq = parallel.pool.DataQueue;
  afterEach(dq, @(msg) fprintf('  [%s s=%.2f] seed %3d %s  (%.0fs elapsed)\n', ...
    msg.paramKey, msg.s, msg.k, msg.tag, toc(tStart)));
catch
  dq = [];
end

% Indexed by ii (1..nRun) inside parfor so the slicing classifier works;
% scattered back into the totalTasks-sized allResults after the parfor so
% the per-cell aggregation below (which uses the linear (pi,si,k) index)
% keeps working whether seeds == 1:K or a subset.
allResults = cell(totalTasks, 1);
runResults = cell(nRun, 1);

parfor ii = 1:nRun
  t = runIdx(ii);
  task = tasks{t};
  ckptFile = task.ckptFile;

  if exist(ckptFile, 'file')
    % Already computed — load and skip. Patch fields missing from old
    % checkpoints (saved before the bonds+BOM TI / flowCC sub-components
    % were captured) so the aggregation loop doesn't error on access.
    tmp = load(ckptFile, 'r');
    rLoaded = tmp.r;
    nP = nPeriods;
    if ~isfield(rLoaded, 'PAM_TI_BOM'),    rLoaded.PAM_TI_BOM    = nan(1,nP); end
    if ~isfield(rLoaded, 'fBonds_trans'),  rLoaded.fBonds_trans  = nan(1,nP); end
    if ~isfield(rLoaded, 'fBonds_transl'), rLoaded.fBonds_transl = nan(1,nP); end
    if ~isfield(rLoaded, 'fBonds_cross'),  rLoaded.fBonds_cross  = nan(1,nP); end
    if ~isfield(rLoaded, 'fBOM_trans'),    rLoaded.fBOM_trans    = nan(1,nP); end
    if ~isfield(rLoaded, 'fBOM_transl'),   rLoaded.fBOM_transl   = nan(1,nP); end
    if ~isfield(rLoaded, 'fBOM_cross'),    rLoaded.fBOM_cross    = nan(1,nP); end
    runResults{ii} = rLoaded;
    if ~isempty(dq)
      send(dq, struct('paramKey',task.paramKey,'s',task.s,'k',task.k,'tag','cached'));
    end
    continue
  end

  tk = getCurrentTask();
  if isempty(tk), wFolder = 'simulatedData';
  else,           wFolder = fullfile('simulatedData', sprintf('worker_%d', tk.ID));
  end
  localSettings = settings;
  localSettings.dataFolder = wFolder;

  r = struct( ...
    'PAM_TI',       nan(1,nPeriods), 'PAM_OCI',      nan(1,nPeriods), ...
    'PAM_TI_BOM',   nan(1,nPeriods), ...
    'M1_TI',        nan(1,nPeriods), 'M1_OCI',       nan(1,nPeriods), ...
    'M2w_TI',       nan(1,nPeriods), 'M2w_OCI',      nan(1,nPeriods), ...
    'M2m_TI',       nan(1,nPeriods), 'M2m_OCI',      nan(1,nPeriods), ...
    'M2q_TI',       nan(1,nPeriods), 'M2q_OCI',      nan(1,nPeriods), ...
    'M1_CC',        nan(1,nPeriods), 'CC_avg',       nan(1,nPeriods), ...
    'CC_close',     nan(1,nPeriods), ...
    'fBonds',       nan(1,nPeriods), 'fBOM',         nan(1,nPeriods), ...
    'fBonds_trans', nan(1,nPeriods), 'fBonds_transl',nan(1,nPeriods), ...
    'fBonds_cross', nan(1,nPeriods), ...
    'fBOM_trans',   nan(1,nPeriods), 'fBOM_transl',  nan(1,nPeriods), ...
    'fBOM_cross',   nan(1,nPeriods));

  try
    createMatFilesSim(dm, task.k, false, wFolder, sandvikArrays, task.timingOverride);
    dc = createDataCompany(dm, localSettings);

    dp = buildPA(dm, dc);
    dr = performanceAttribution(dm, dc, dp, false);
    for p = 1:nPeriods
      idx = quarterIdx{p};
      if ~isempty(idx)
        r.PAM_TI(p)     = sum(dr.dFX_trans(idx));        % bonds-only PAM TI
        r.PAM_TI_BOM(p) = sum(dr.dFX_trans_BOM(idx));    % bonds + BOM PAM TI (full economic exposure)
        r.PAM_OCI(p)    = sum(dr.dFX_transl(idx));       % PAM translation / OCI
      end
    end

    bs  = buildBalanceSheet(dm, dc);
    pnl = buildFunctionalPnL(dm, dc, bs);

    m1 = computeMethod1(dm, dc, '', bs, pnl);
    r.M1_TI  = m1.TI(:)';
    r.M1_OCI = m1.OCI(:)';

    m2 = computeMethod2(dm, dc, '', bs, pnl);
    r.M2w_TI = m2.weekly.TI(:)';     r.M2w_OCI = m2.weekly.OCI(:)';
    r.M2m_TI = m2.monthly.TI(:)';    r.M2m_OCI = m2.monthly.OCI(:)';
    r.M2q_TI = m2.quarterly.TI(:)';  r.M2q_OCI = m2.quarterly.OCI(:)';

    P = min(length(m1.cc.M1.quarterly_TI), nPeriods);
    r.M1_CC(1:P)    = (m1.cc.M1.quarterly_TI(1:P)    + m1.cc.M1.quarterly_OCI(1:P))';
    r.CC_avg(1:P)   = (m1.cc.avg.quarterly_TI(1:P)   + m1.cc.avg.quarterly_OCI(1:P))';
    r.CC_close(1:P) = (m1.cc.close.quarterly_TI(1:P) + m1.cc.close.quarterly_OCI(1:P))';

    fcc = performanceAttributionFlowCC(dm, dc, pnl);
    Pf  = min(length(fcc.bonds.total_quarterly), nPeriods);
    % Totals (used as CC benchmarks); keep historical fBonds/fBOM names.
    r.fBonds(1:Pf) = fcc.bonds.total_quarterly(1:Pf)';
    r.fBOM(1:Pf)   = fcc.BOM.total_quarterly(1:Pf)';
    % Sub-components (mirrors runMC's flowCC_{bonds,BOM}_{trans,transl,cross}).
    r.fBonds_trans(1:Pf)  = fcc.bonds.trans_quarterly(1:Pf)';
    r.fBonds_transl(1:Pf) = fcc.bonds.transl_quarterly(1:Pf)';
    r.fBonds_cross(1:Pf)  = fcc.bonds.cross_quarterly(1:Pf)';
    r.fBOM_trans(1:Pf)    = fcc.BOM.trans_quarterly(1:Pf)';
    r.fBOM_transl(1:Pf)   = fcc.BOM.transl_quarterly(1:Pf)';
    r.fBOM_cross(1:Pf)    = fcc.BOM.cross_quarterly(1:Pf)';
  catch ME
    fprintf(2, '\n  task %d (%s s=%.2f seed=%d) ERROR: %s\n', ...
      t, task.paramKey, task.s, task.k, ME.message);
  end

  saveCheckpoint(ckptFile, r);
  runResults{ii} = r;
  if ~isempty(dq)
    send(dq, struct('paramKey',task.paramKey,'s',task.s,'k',task.k,'tag','done'));
  end
end

% Scatter parfor-local runResults back into the full-size allResults so
% the per-cell aggregation below can use the linear (pi,si,k) index. If
% seeds covers all of 1:K, this fills allResults completely; otherwise
% slots outside this machine's seeds stay empty and the `if isempty(r),
% continue` check in the aggregation loop skips them.
for ii = 1:nRun
  allResults{runIdx(ii)} = runResults{ii};
end

fprintf('\nAll iterations finished in %.1fs. Aggregating per cell...\n\n', toc(tStart));

% =========================================================================
% AGGREGATE per (param, scaling) cell -> rmse/me using the flat results.
% Identical arithmetic to the previous per-cell aggregation step.
% =========================================================================
for pi = 1:nParams
  paramKey = paramSweeps{pi, 1};
  for si = 1:nScales
    s = scalings(si);
    base = ((pi-1) * nScales + (si-1)) * K;

    PAM_TI     = nan(K, nPeriods);
    PAM_TI_BOM = nan(K, nPeriods);
    PAM_OCI    = nan(K, nPeriods);
    M1_TI      = nan(K, nPeriods);   M1_OCI   = nan(K, nPeriods);
    M2w_TI     = nan(K, nPeriods);   M2w_OCI  = nan(K, nPeriods);
    M2m_TI     = nan(K, nPeriods);   M2m_OCI  = nan(K, nPeriods);
    M2q_TI     = nan(K, nPeriods);   M2q_OCI  = nan(K, nPeriods);
    M1_CC      = nan(K, nPeriods);
    CC_avg     = nan(K, nPeriods);
    CC_close   = nan(K, nPeriods);
    fBonds     = nan(K, nPeriods);
    fBOM       = nan(K, nPeriods);

    for k = 1:K
      r = allResults{base + k};
      if isempty(r), continue; end
      PAM_TI(k,:)     = r.PAM_TI;
      PAM_TI_BOM(k,:) = r.PAM_TI_BOM;
      PAM_OCI(k,:)    = r.PAM_OCI;
      M1_TI(k,:)    = r.M1_TI;     M1_OCI(k,:)   = r.M1_OCI;
      M2w_TI(k,:)   = r.M2w_TI;    M2w_OCI(k,:)  = r.M2w_OCI;
      M2m_TI(k,:)   = r.M2m_TI;    M2m_OCI(k,:)  = r.M2m_OCI;
      M2q_TI(k,:)   = r.M2q_TI;    M2q_OCI(k,:)  = r.M2q_OCI;
      M1_CC(k,:)    = r.M1_CC;
      CC_avg(k,:)   = r.CC_avg;
      CC_close(k,:) = r.CC_close;
      fBonds(k,:)   = r.fBonds;
      fBOM(k,:)     = r.fBOM;
    end

    % Original valid mask — only requires fields needed for legacy metrics.
    % New metrics (rmse_TI_BOM, rmse_CC_bonds) will produce NaN per cell if
    % their inputs are NaN (e.g. when loading old checkpoints that predate
    % the bonds+BOM capture), without affecting the original metrics.
    valid = ~any(isnan(PAM_TI),2) & ~any(isnan(PAM_OCI),2) & ...
            ~any(isnan(M1_TI),2)  & ~any(isnan(M2m_TI),2) & ...
            ~any(isnan(fBOM),2);

    rmse = @(A,B) sqrt(mean((A(valid,:) - B(valid,:)).^2, 'all'));
    me   = @(A,B) mean(A(valid,:) - B(valid,:), 'all');

    % TI vs bonds-only PAM (FX_trans). What M1/M2 ARE trying to track.
    results.rmse_TI.M1(pi,si)  = rmse(PAM_TI, M1_TI);   results.me_TI.M1(pi,si)  = me(PAM_TI, M1_TI);
    results.rmse_TI.M2w(pi,si) = rmse(PAM_TI, M2w_TI);  results.me_TI.M2w(pi,si) = me(PAM_TI, M2w_TI);
    results.rmse_TI.M2m(pi,si) = rmse(PAM_TI, M2m_TI);  results.me_TI.M2m(pi,si) = me(PAM_TI, M2m_TI);
    results.rmse_TI.M2q(pi,si) = rmse(PAM_TI, M2q_TI);  results.me_TI.M2q(pi,si) = me(PAM_TI, M2q_TI);

    % TI vs bonds+BOM PAM (FX_trans_BOM). What PAM uniquely captures via the BOM phase.
    results.rmse_TI_BOM.M1(pi,si)  = rmse(PAM_TI_BOM, M1_TI);   results.me_TI_BOM.M1(pi,si)  = me(PAM_TI_BOM, M1_TI);
    results.rmse_TI_BOM.M2w(pi,si) = rmse(PAM_TI_BOM, M2w_TI);  results.me_TI_BOM.M2w(pi,si) = me(PAM_TI_BOM, M2w_TI);
    results.rmse_TI_BOM.M2m(pi,si) = rmse(PAM_TI_BOM, M2m_TI);  results.me_TI_BOM.M2m(pi,si) = me(PAM_TI_BOM, M2m_TI);
    results.rmse_TI_BOM.M2q(pi,si) = rmse(PAM_TI_BOM, M2q_TI);  results.me_TI_BOM.M2q(pi,si) = me(PAM_TI_BOM, M2q_TI);

    results.rmse_OCI.M1(pi,si)  = rmse(PAM_OCI, M1_OCI);   results.me_OCI.M1(pi,si)  = me(PAM_OCI, M1_OCI);
    results.rmse_OCI.M2w(pi,si) = rmse(PAM_OCI, M2w_OCI);  results.me_OCI.M2w(pi,si) = me(PAM_OCI, M2w_OCI);
    results.rmse_OCI.M2m(pi,si) = rmse(PAM_OCI, M2m_OCI);  results.me_OCI.M2m(pi,si) = me(PAM_OCI, M2m_OCI);
    results.rmse_OCI.M2q(pi,si) = rmse(PAM_OCI, M2q_OCI);  results.me_OCI.M2q(pi,si) = me(PAM_OCI, M2q_OCI);

    % CC vs PAM BOM-flow (full economic CC).
    results.rmse_CC.M1_CC(pi,si)     = rmse(fBOM, M1_CC);    results.me_CC.M1_CC(pi,si)     = me(fBOM, M1_CC);
    results.rmse_CC.CC_avg(pi,si)    = rmse(fBOM, CC_avg);   results.me_CC.CC_avg(pi,si)    = me(fBOM, CC_avg);
    results.rmse_CC.CC_close(pi,si)  = rmse(fBOM, CC_close); results.me_CC.CC_close(pi,si)  = me(fBOM, CC_close);
    results.rmse_CC.PAM_bonds(pi,si) = rmse(fBOM, fBonds);   results.me_CC.PAM_bonds(pi,si) = me(fBOM, fBonds);

    % CC vs PAM bonds-flow (recognised-only CC). What M1/M2 CC variants ARE trying to track.
    results.rmse_CC_bonds.M1_CC(pi,si)    = rmse(fBonds, M1_CC);    results.me_CC_bonds.M1_CC(pi,si)    = me(fBonds, M1_CC);
    results.rmse_CC_bonds.CC_avg(pi,si)   = rmse(fBonds, CC_avg);   results.me_CC_bonds.CC_avg(pi,si)   = me(fBonds, CC_avg);
    results.rmse_CC_bonds.CC_close(pi,si) = rmse(fBonds, CC_close); results.me_CC_bonds.CC_close(pi,si) = me(fBonds, CC_close);

    fprintf(['[%s s=%.2f] RMSE TI/M1 bonds=%.1fM  BOM=%.1fM | OCI/M1=%.1fM | ' ...
             'CC/M1 BOM=%.1fM  bonds=%.1fM | BOM-phase=%.1fM\n'], ...
      paramKey, s, ...
      results.rmse_TI.M1(pi,si)/1e6, results.rmse_TI_BOM.M1(pi,si)/1e6, ...
      results.rmse_OCI.M1(pi,si)/1e6, ...
      results.rmse_CC.M1_CC(pi,si)/1e6, results.rmse_CC_bonds.M1_CC(pi,si)/1e6, ...
      results.rmse_CC.PAM_bonds(pi,si)/1e6);
  end
end

fprintf('\nSensitivity sweep complete. Total time: %.1fs\n\n', toc(tStart));

% =========================================================================
% SAVE
% =========================================================================
save('sensitivity_results.mat', 'results', 'paramSweeps', 'baseline');
fprintf('Results saved to sensitivity_results.mat\n');

% =========================================================================
% CONSOLE SUMMARY  (one table per param, RMSE per method)
%
% Two TI rows per method (vs bonds-only PAM, vs bonds+BOM PAM):
%   *_b  -> vs FX_trans      (the accounting-comparable benchmark)
%   *_B  -> vs FX_trans_BOM  (the full PAM economic exposure)
% Two CC rows per accounting method (vs BOM-flow, vs bonds-flow):
%   *_B  -> vs flowCC_BOM_total
%   *_b  -> vs flowCC_bonds_total
% =========================================================================
for pi = 1:nParams
  fprintf('\n=== %s — RMSE in SEK million (rows: methods, cols: scaling s) ===\n', ...
    paramSweeps{pi, 2});
  fprintf('%-18s', 'Method');
  for si = 1:nScales, fprintf('%10s', sprintf('s=%.2f', scalings(si))); end
  fprintf('\n%s\n', repmat('-', 1, 18 + 10*nScales));

  printRMSErow('TI/M1   vs bonds',  results.rmse_TI.M1(pi,:),       nScales);
  printRMSErow('TI/M1   vs BOM',    results.rmse_TI_BOM.M1(pi,:),   nScales);
  printRMSErow('TI/M2w  vs bonds',  results.rmse_TI.M2w(pi,:),      nScales);
  printRMSErow('TI/M2w  vs BOM',    results.rmse_TI_BOM.M2w(pi,:),  nScales);
  printRMSErow('TI/M2m  vs bonds',  results.rmse_TI.M2m(pi,:),      nScales);
  printRMSErow('TI/M2m  vs BOM',    results.rmse_TI_BOM.M2m(pi,:),  nScales);
  printRMSErow('TI/M2q  vs bonds',  results.rmse_TI.M2q(pi,:),      nScales);
  printRMSErow('TI/M2q  vs BOM',    results.rmse_TI_BOM.M2q(pi,:),  nScales);
  printRMSErow('OCI/M1',            results.rmse_OCI.M1(pi,:),      nScales);
  printRMSErow('OCI/M2m',           results.rmse_OCI.M2m(pi,:),     nScales);
  printRMSErow('CC/M1   vs BOM',    results.rmse_CC.M1_CC(pi,:),    nScales);
  printRMSErow('CC/M1   vs bonds',  results.rmse_CC_bonds.M1_CC(pi,:),  nScales);
  printRMSErow('CC/avg  vs BOM',    results.rmse_CC.CC_avg(pi,:),   nScales);
  printRMSErow('CC/avg  vs bonds',  results.rmse_CC_bonds.CC_avg(pi,:), nScales);
  printRMSErow('CC/close vs BOM',   results.rmse_CC.CC_close(pi,:), nScales);
  printRMSErow('CC/close vs bonds', results.rmse_CC_bonds.CC_close(pi,:), nScales);
  printRMSErow('CC bonds vs BOM',   results.rmse_CC.PAM_bonds(pi,:),nScales);  % BOM-phase size
end

% =========================================================================
% PLOTS — one figure per parameter, 2x3 subplots:
%   Row 1: TI vs PAM bonds-only | OCI | CC vs PAM BOM-flow   (the "accounting-comparable" benchmarks)
%   Row 2: TI vs PAM bonds+BOM  | (legend) | CC vs PAM bonds-flow   (the "full PAM" benchmarks)
%
% The row-1 plots ask: "Within the scope each accounting method targets,
% how close does it get to PAM?" The row-2 plots ask: "How big is the gap
% caused by PAM's extra BOM-phase coverage that accounting methods miss?"
% Both perspectives are needed for the thesis comparison.
% =========================================================================
cM1    = [0.89 0.10 0.11];  % red
cM2w   = [0.99 0.55 0.24];  % orange
cM2m   = [0.20 0.63 0.17];  % green
cM2q   = [0.55 0.34 0.72];  % purple
cPAM   = [0.12 0.47 0.71];  % blue
cCCavg = [0.60 0.40 0.12];  % brown
cCCcls = [0.84 0.19 0.87];  % pink

% Set up figures folder matching runMC convention
figDir = fullfile(pwd, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end

for pi = 1:nParams
  fh = figure(100 + pi); clf;
  paramLabel = paramSweeps{pi, 2};
  paramKey   = paramSweeps{pi, 1};

  % --- Row 1, Col 1: TI vs PAM bonds-only (accounting-comparable) ---
  subplot(2,3,1); hold on;
  plot(scalings, results.rmse_TI.M1(pi,:)/1e6,  '-o', 'Color',cM1,  'LineWidth',1.6,'DisplayName','M1');
  plot(scalings, results.rmse_TI.M2w(pi,:)/1e6, '-o', 'Color',cM2w, 'LineWidth',1.6,'DisplayName','M2 weekly');
  plot(scalings, results.rmse_TI.M2m(pi,:)/1e6, '-o', 'Color',cM2m, 'LineWidth',1.6,'DisplayName','M2 monthly');
  plot(scalings, results.rmse_TI.M2q(pi,:)/1e6, '-o', 'Color',cM2q, 'LineWidth',1.6,'DisplayName','M2 quarterly');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('TI vs PAM bonds (FX\_trans)'); legend('Location','Best');

  % --- Row 1, Col 2: OCI (unchanged — translation has only one benchmark) ---
  subplot(2,3,2); hold on;
  plot(scalings, results.rmse_OCI.M1(pi,:)/1e6,  '-o', 'Color',cM1,  'LineWidth',1.6,'DisplayName','M1 OCI');
  plot(scalings, results.rmse_OCI.M2w(pi,:)/1e6, '-o', 'Color',cM2w, 'LineWidth',1.6,'DisplayName','M2 weekly');
  plot(scalings, results.rmse_OCI.M2m(pi,:)/1e6, '-o', 'Color',cM2m, 'LineWidth',1.6,'DisplayName','M2 monthly');
  plot(scalings, results.rmse_OCI.M2q(pi,:)/1e6, '-o', 'Color',cM2q, 'LineWidth',1.6,'DisplayName','M2 quarterly');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('OCI (FX\_transl)'); legend('Location','Best');

  % --- Row 1, Col 3: CC vs PAM BOM-flow (full economic CC) ---
  subplot(2,3,3); hold on;
  plot(scalings, results.rmse_CC.M1_CC(pi,:)/1e6,     '-o', 'Color',cM1,    'LineWidth',1.6,'DisplayName','M1 CC');
  plot(scalings, results.rmse_CC.CC_avg(pi,:)/1e6,    '-o', 'Color',cCCavg, 'LineWidth',1.6,'DisplayName','CC avg');
  plot(scalings, results.rmse_CC.CC_close(pi,:)/1e6,  '-o', 'Color',cCCcls, 'LineWidth',1.6,'DisplayName','CC close');
  plot(scalings, results.rmse_CC.PAM_bonds(pi,:)/1e6, '-o', 'Color',cPAM,   'LineWidth',1.6,'DisplayName','PAM bonds');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('CC vs PAM BOM-flow'); legend('Location','Best');

  % --- Row 2, Col 1: TI vs PAM bonds+BOM (full PAM exposure) ---
  subplot(2,3,4); hold on;
  plot(scalings, results.rmse_TI_BOM.M1(pi,:)/1e6,  '-o', 'Color',cM1,  'LineWidth',1.6,'DisplayName','M1');
  plot(scalings, results.rmse_TI_BOM.M2w(pi,:)/1e6, '-o', 'Color',cM2w, 'LineWidth',1.6,'DisplayName','M2 weekly');
  plot(scalings, results.rmse_TI_BOM.M2m(pi,:)/1e6, '-o', 'Color',cM2m, 'LineWidth',1.6,'DisplayName','M2 monthly');
  plot(scalings, results.rmse_TI_BOM.M2q(pi,:)/1e6, '-o', 'Color',cM2q, 'LineWidth',1.6,'DisplayName','M2 quarterly');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('TI vs PAM bonds+BOM (FX\_trans\_BOM)'); legend('Location','Best');

  % --- Row 2, Col 2: empty (or annotation) ---
  subplot(2,3,5); axis off;
  text(0.5, 0.5, sprintf(['Row 1: accounting-comparable benchmarks\n' ...
                          '(what M1/M2 try to track)\n\n' ...
                          'Row 2: full PAM benchmarks\n' ...
                          '(what M1/M2 structurally cannot track)\n\n' ...
                          'Gap = BOM-phase exposure size']), ...
       'HorizontalAlignment','center', 'VerticalAlignment','middle', ...
       'FontSize',9);

  % --- Row 2, Col 3: CC vs PAM bonds-flow (recognised-only CC) ---
  subplot(2,3,6); hold on;
  plot(scalings, results.rmse_CC_bonds.M1_CC(pi,:)/1e6,    '-o', 'Color',cM1,    'LineWidth',1.6,'DisplayName','M1 CC');
  plot(scalings, results.rmse_CC_bonds.CC_avg(pi,:)/1e6,   '-o', 'Color',cCCavg, 'LineWidth',1.6,'DisplayName','CC avg');
  plot(scalings, results.rmse_CC_bonds.CC_close(pi,:)/1e6, '-o', 'Color',cCCcls, 'LineWidth',1.6,'DisplayName','CC close');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('CC vs PAM bonds-flow'); legend('Location','Best');

  sgtitle(paramLabel);

  % Apply consistent font sizes to all subplots
  axs = findall(fh, 'Type', 'axes');
  for ai = 1:length(axs)
    axs(ai).FontSize = 9;
    if ~isempty(axs(ai).Title)
      axs(ai).Title.FontSize = 10;
      axs(ai).Title.FontWeight = 'bold';
    end
    axs(ai).XLabel.FontSize = 10;
    axs(ai).YLabel.FontSize = 10;
    if ~isempty(axs(ai).Legend)
      axs(ai).Legend.FontSize = 8;
    end
  end

  % Size and save as PDF (taller for 2 rows)
  set(fh, 'Units','centimeters', 'Position',[0 0 26 16]);
  set(fh, 'PaperUnits','centimeters', 'PaperSize',[26 16], ...
          'PaperPosition',[0 0 26 16], 'PaperPositionMode','manual');
  pdfName = fullfile(figDir, sprintf('sensitivity_%s.pdf', paramKey));
  saveas(fh, pdfName);
  fprintf('  Figure saved: %s\n', pdfName);
end

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================
function printRMSErow(label, row, nScales)
  fprintf('%-18s', label);
  for si = 1:nScales
    fprintf('%10.2f', row(si) / 1e6);
  end
  fprintf('\n');
end

function saveCheckpoint(fname, r) %#ok<INUSD>
% Wrapper so save can be called from inside parfor (direct save is not allowed).
  save(fname, 'r');
end
