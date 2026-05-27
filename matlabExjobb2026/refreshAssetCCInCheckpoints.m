% refreshAssetCCInCheckpoints  Add PAM CC asset-walk (pamCC_*) fields to
% existing MC checkpoints without redoing M1/M2, flow CC, or PAM
% portfolio-level CC.
%
% Per-seed cost (Light variant — skips performanceAttribution):
%   createMatFilesSim + createDataCompany + buildPA +
%   buildBalanceSheet + buildFunctionalPnL + performanceAttributionAssetCC
%
% Roughly 1.5 min per seed (vs 4-5 min full runMC seed). Total for K=5000
% with 2 workers: ~2 days (vs ~5 days full).
%
% Fields added/overwritten per checkpoint (8 new fields):
%   r.pamCC_bonds_{trans, transl, cross, total}
%   r.pamCC_BOM_{trans, transl, cross, total}
%
% Fields stripped (legacy from earlier runs, no longer in use):
%   r.flowCC_bonds_*, r.flowCC_BOM_*  (flow CC — removed in cleanup)
%   r.pamCC_*_froze_*, r.pamCC_*_roll_*  (old froze/roll naming — replaced)
%
% Fields preserved (verified untouched by this refresh):
%   r.FX_trans, r.FX_trans_BOM, r.FX_transl   (PAM TI/OCI)
%   r.M1_*, r.M2{w,m,q}_*                      (industry TI/OCI)
%   r.M1_CC_*, r.CC_avg_*, r.CC_close_*        (industry CC)
%   r.actRevEUR, r.actGMpct, r.netExpPct       (sim metadata)
%
% Usage:
%   K = 5000; refreshAssetCCInCheckpoints           % all 5000 seeds
%   K = 5000; seeds = 1:2500; refreshAssetCCInCheckpoints  % subset

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

% --- Identify checkpoints to process -------------------------------------
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

% --- Parallel refresh ----------------------------------------------------
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

    % Rebuild dc + dp (PAM core — needed for asset CC)
    dc = createDataCompany(dm, localSettings);
    dp = buildPA(dm, dc);

    % bs + pnl needed only for pnl.quarterStartIdx/EndIdx
    bs  = buildBalanceSheet(dm, dc);
    pnl = buildFunctionalPnL(dm, dc, bs);

    % Compute new asset-walk PAM CC (the only NEW field set)
    pcc = performanceAttributionAssetCC(dm, dc, dp, pnl);

    % Load existing checkpoint and update only pamCC_* fields
    tmp = load(ckptFile, 'r');
    r = tmp.r;
    nP = length(r.FX_trans);

    % Strip legacy fields (from cleanup) before adding new ones
    legacyFields = {'flowCC_bonds_trans','flowCC_bonds_transl','flowCC_bonds_cross','flowCC_bonds_total', ...
                    'flowCC_BOM_trans',  'flowCC_BOM_transl',  'flowCC_BOM_cross',  'flowCC_BOM_total', ...
                    'flowCC_BOMext_trans','flowCC_BOMext_transl','flowCC_BOMext_cross','flowCC_BOMext_total', ...
                    'pamCC_bonds_froze_trans','pamCC_bonds_froze_transl','pamCC_bonds_froze_cross','pamCC_bonds_froze_total', ...
                    'pamCC_bonds_roll_trans', 'pamCC_bonds_roll_transl', 'pamCC_bonds_roll_cross', 'pamCC_bonds_roll_total', ...
                    'pamCC_BOM_froze_trans',  'pamCC_BOM_froze_transl',  'pamCC_BOM_froze_cross',  'pamCC_BOM_froze_total', ...
                    'pamCC_BOM_roll_trans',   'pamCC_BOM_roll_transl',   'pamCC_BOM_roll_cross',   'pamCC_BOM_roll_total'};
    for fi = 1:length(legacyFields)
      if isfield(r, legacyFields{fi}), r = rmfield(r, legacyFields{fi}); end
    end

    % Add 8 new pamCC_* fields
    r.pamCC_bonds_trans  = nan(1, nP);
    r.pamCC_bonds_transl = nan(1, nP);
    r.pamCC_bonds_cross  = nan(1, nP);
    r.pamCC_bonds_total  = nan(1, nP);
    r.pamCC_BOM_trans    = nan(1, nP);
    r.pamCC_BOM_transl   = nan(1, nP);
    r.pamCC_BOM_cross    = nan(1, nP);
    r.pamCC_BOM_total    = nan(1, nP);

    Pa = min(length(pcc.bonds.total_quarterly), nP);
    r.pamCC_bonds_trans(1:Pa)  = pcc.bonds.trans_quarterly(1:Pa)';
    r.pamCC_bonds_transl(1:Pa) = pcc.bonds.transl_quarterly(1:Pa)';
    r.pamCC_bonds_cross(1:Pa)  = pcc.bonds.cross_quarterly(1:Pa)';
    r.pamCC_bonds_total(1:Pa)  = pcc.bonds.total_quarterly(1:Pa)';
    r.pamCC_BOM_trans(1:Pa)    = pcc.BOM.trans_quarterly(1:Pa)';
    r.pamCC_BOM_transl(1:Pa)   = pcc.BOM.transl_quarterly(1:Pa)';
    r.pamCC_BOM_cross(1:Pa)    = pcc.BOM.cross_quarterly(1:Pa)';
    r.pamCC_BOM_total(1:Pa)    = pcc.BOM.total_quarterly(1:Pa)';

    saveCheckpoint(ckptFile, r);
  catch ME
    fprintf(2, '  seed %d: ERROR: %s\n', k, ME.message);
    fprintf(2, '  seed %d: identifier: %s\n', k, ME.identifier);
    for s = 1:length(ME.stack)
      fprintf(2, '    at %s (line %d) in %s\n', ...
        ME.stack(s).name, ME.stack(s).line, ME.stack(s).file);
    end
  end

  if ~isempty(dq), send(dq, k); end
end

fprintf('\nDone. Refreshed %d checkpoints in %.1fs (%.1f min).\n', ...
  nProcess, toc(tStart), toc(tStart)/60);
fprintf('Run runMC again to aggregate; every seed will skip via the\n');
fprintf('"checkpoint exists" path and only the report will be produced.\n');

function saveCheckpoint(fname, r) %#ok<INUSD>
  save(fname, 'r');
end
