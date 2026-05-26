% refreshCCInCheckpoints  Recompute PAM flow CC in existing MC checkpoints.
%
% Use this script after the BOM CC anchor change (commit 2432d8e) to
% refresh the flowCC_{bonds,BOM}_* fields in existing 5000-seed
% checkpoints WITHOUT redoing the expensive PAM bond accounting
% (buildPA + performanceAttribution) or industry methods (computeMethod1
% + computeMethod2). Those fields are deterministic from the seed and
% haven't changed, so they stay as-is.
%
% Per-seed cost: createMatFilesSim + createDataCompany + buildBalanceSheet
% + buildFunctionalPnL + performanceAttributionFlowCC. Roughly 40-50% of
% a full runMC seed (the PAM/M1/M2 step is skipped).
%
% Usage:
%   K = 5000; refreshCCInCheckpoints                % refresh all 5000 seeds
%   K = 5000; seeds = 1:2500; refreshCCInCheckpoints % only this machine's range
%
% The script loads each existing checkpoint, regenerates simulation data
% deterministically from the seed, recomputes fcc, and OVERWRITES the
% flowCC_{bonds,BOM}_{trans,transl,cross,total} fields. All other fields
% (PAM_TI, PAM_OCI, M1_*, M2_*, M1_CC_*, etc.) are preserved unchanged.
%
% Skips:
%   - missing checkpoints (no work)
%   - checkpoints that already error during recompute (logs and continues)

if ~exist('K', 'var'),     K     = 5000;             end
if ~exist('seeds', 'var'), seeds = 1:K;              end
ckptDir = 'mc_checkpoints';

if ~exist(ckptDir, 'dir')
  error('Checkpoint folder not found: %s', ckptDir);
end

% --- Settings (mirror runMC) ---------------------------------------------
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

% --- Load market data + Sandvik calibration once -------------------------
if ~exist('dm', 'var') || ~isfield(dm,'cName')
  fprintf('Loading market data...\n');
  dm = createDataMarket('reutersZero', settings);
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

% --- Identify checkpoints in the requested seed range --------------------
seedsToProcess = [];
for k = seeds(:)'
  f = fullfile(ckptDir, sprintf('seed_%04d.mat', k));
  if exist(f, 'file'), seedsToProcess(end+1, 1) = k; end %#ok<AGROW>
end
nProcess = length(seedsToProcess);
fprintf('Found %d existing checkpoints to refresh in seed range [%d, %d]\n', ...
  nProcess, min(seeds), max(seeds));

if nProcess == 0
  fprintf('Nothing to do.\n');
  return;
end

tStart = tic;

% --- Progress queue ------------------------------------------------------
try
  dq = parallel.pool.DataQueue;
  afterEach(dq, @(k) fprintf('  Seed %4d refreshed (%.0fs elapsed)\n', ...
    k, toc(tStart)));
catch
  dq = [];
end

% --- Parallel recompute --------------------------------------------------
parfor ii = 1:length(seedsToProcess)
  k = seedsToProcess(ii);
  ckptFile = fullfile(ckptDir, sprintf('seed_%04d.mat', k));

  % Per-worker folder to avoid file-IO collisions
  tk = getCurrentTask();
  if isempty(tk), wFolder = 'simulatedData';
  else,           wFolder = fullfile('simulatedData', sprintf('worker_%d', tk.ID));
  end
  localSettings = settings;
  localSettings.dataFolder = wFolder;

  try
    % Reproduce the exact same simulation data this seed used originally
    createMatFilesSim(dm, k, false, wFolder, sandvikArrays);

    % Rebuild dc / bs / pnl (deterministic from simulated data)
    dc  = createDataCompany(dm, localSettings);
    bs  = buildBalanceSheet(dm, dc);
    pnl = buildFunctionalPnL(dm, dc, bs);

    % Compute new fcc (BOM now uses ord-anchored PY)
    fcc = performanceAttributionFlowCC(dm, dc, pnl);

    % Load existing checkpoint and OVERWRITE only the flowCC_* fields
    tmp = load(ckptFile, 'r');
    r = tmp.r;

    nP = length(r.FX_trans);
    Pf = min(length(fcc.bonds.total_quarterly), nP);

    % Re-allocate the flowCC_* fields (they exist in the checkpoint but
    % we overwrite them rather than assuming the shape is unchanged)
    r.flowCC_bonds_trans  = nan(1, nP);
    r.flowCC_bonds_transl = nan(1, nP);
    r.flowCC_bonds_cross  = nan(1, nP);
    r.flowCC_bonds_total  = nan(1, nP);
    r.flowCC_BOM_trans    = nan(1, nP);
    r.flowCC_BOM_transl   = nan(1, nP);
    r.flowCC_BOM_cross    = nan(1, nP);
    r.flowCC_BOM_total    = nan(1, nP);

    r.flowCC_bonds_trans(1:Pf)  = fcc.bonds.trans_quarterly(1:Pf)';
    r.flowCC_bonds_transl(1:Pf) = fcc.bonds.transl_quarterly(1:Pf)';
    r.flowCC_bonds_cross(1:Pf)  = fcc.bonds.cross_quarterly(1:Pf)';
    r.flowCC_bonds_total(1:Pf)  = fcc.bonds.total_quarterly(1:Pf)';
    r.flowCC_BOM_trans(1:Pf)    = fcc.BOM.trans_quarterly(1:Pf)';
    r.flowCC_BOM_transl(1:Pf)   = fcc.BOM.transl_quarterly(1:Pf)';
    r.flowCC_BOM_cross(1:Pf)    = fcc.BOM.cross_quarterly(1:Pf)';
    r.flowCC_BOM_total(1:Pf)    = fcc.BOM.total_quarterly(1:Pf)';

    % Strip any leftover BOMext fields from earlier runs (they're gone now)
    if isfield(r, 'flowCC_BOMext_trans'),  r = rmfield(r, 'flowCC_BOMext_trans');  end
    if isfield(r, 'flowCC_BOMext_transl'), r = rmfield(r, 'flowCC_BOMext_transl'); end
    if isfield(r, 'flowCC_BOMext_cross'),  r = rmfield(r, 'flowCC_BOMext_cross');  end
    if isfield(r, 'flowCC_BOMext_total'),  r = rmfield(r, 'flowCC_BOMext_total');  end

    saveCheckpoint(ckptFile, r);
  catch ME
    fprintf(2, '  seed %d: ERROR: %s\n', k, ME.message);
  end

  if ~isempty(dq), send(dq, k); end
end

fprintf('\nDone. Refreshed %d checkpoints in %.1fs.\n', nProcess, toc(tStart));
fprintf('Run runMC again to aggregate — it will skip every seed via the\n');
fprintf('"checkpoint exists" path and just produce the report with the new BOM CC.\n');

function saveCheckpoint(fname, r) %#ok<INUSD>
  save(fname, 'r');
end
