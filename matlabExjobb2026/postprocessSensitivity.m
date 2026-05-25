function postprocessSensitivity(ckptDir, figDir)
% postprocessSensitivity  Generate runMC-style figures for every (param, scaling)
% cell of a completed sensitivity sweep.
%
%   postprocessSensitivity()
%   postprocessSensitivity('sensitivity_checkpoints', 'figures')
%
% Reads the per-iteration checkpoints written by runSensitivity, aggregates
% them per cell, and produces 19 PDFs in figDir. Each PDF is a 4x5 grid of
% panels:
%   rows    = timing parameters (procLead, mfg, custPay, suppPay)
%   columns = scaling levels    (s = 0, 0.25, 0.5, 0.75, 1)
%   panel   = a runMC-style chart of that single (param, scaling) cell
%
% Files written to figDir/:
%   sensitivity_TI_actual.pdf            sensitivity_TI_actual_cum.pdf
%   sensitivity_TI_errors_box.pdf
%   sensitivity_TI_errors_kde_bonds.pdf  sensitivity_TI_errors_kde_bom.pdf
%   sensitivity_TI_std_hist_bonds.pdf    sensitivity_TI_std_hist_bom.pdf
%   sensitivity_OCI_actual.pdf           sensitivity_OCI_actual_cum.pdf
%   sensitivity_OCI_errors_box.pdf       sensitivity_OCI_errors_kde.pdf
%   sensitivity_OCI_std_hist.pdf
%   sensitivity_CC_actual.pdf            sensitivity_CC_actual_cum.pdf
%   sensitivity_CC_errors_box.pdf
%   sensitivity_CC_errors_kde_bonds.pdf  sensitivity_CC_errors_kde_bom.pdf
%   sensitivity_CC_std_hist_bonds.pdf    sensitivity_CC_std_hist_bom.pdf
%
% Does NOT re-run the simulation pipeline. Safe to iterate on figure layout
% by re-running this script after a single (slow) runSensitivity run.

if nargin < 1 || isempty(ckptDir), ckptDir = 'sensitivity_checkpoints'; end
% Default output: figures/sensitivity/ so the 19 PDFs don't mix with
% runMC's baseline outputs that share the figures/ root.
if nargin < 2 || isempty(figDir),  figDir  = fullfile('figures', 'sensitivity'); end
if ~exist(figDir, 'dir'), mkdir(figDir); end

% =========================================================================
% LOAD ALL CHECKPOINTS, INDEX BY (paramKey, scaling, seed)
% =========================================================================
fprintf('Loading checkpoints from %s...\n', ckptDir);
[data, paramKeys, paramLabels, scalings, K, nPeriods] = loadAllCheckpoints(ckptDir);
nParams = length(paramKeys);
nScales = length(scalings);
fprintf('  %d params x %d scalings x K=%d, nPeriods=%d\n', nParams, nScales, K, nPeriods);

% =========================================================================
% PALETTE  (matches runMC)
% =========================================================================
cM1    = [0.89 0.10 0.11];
cM2w   = [0.99 0.55 0.24];
cM2m   = [0.20 0.63 0.17];
cM2q   = [0.55 0.34 0.72];
cPAM   = [0.12 0.47 0.71];
cCCavg = [0.60 0.40 0.12];
cCCcls = [0.84 0.19 0.87];

% X-axis index per quarter (sparse year labels assuming Q1 starts at sim start)
qx        = 1:nPeriods;
[xTicks, xTickLbls] = yearTicks(nPeriods);
% CC plots typically skip 2007 (no prior-year rates) -> show 2008+ if applicable
nPeriodsCC = nPeriods;  % adjust below per chart group if we trim
ccQx        = 1:nPeriodsCC;
[ccXTicks, ccXTickLbls] = yearTicks(nPeriodsCC);

% =========================================================================
% SECTION 1 — TRANSACTIONAL (TI)
% =========================================================================
fprintf('\nGenerating TI figures...\n');

% Series order (legend will use this order across panels)
TI.series = { ...
  'PAM_TI',     'PAM bonds',      cPAM, '-o',  1.0;  ...
  'PAM_TI_BOM', 'PAM bonds+BOM',  cPAM, '--s', 0.7;  ...
  'M1_TI',      'M1',             cM1,  '-',   0.7;  ...
  'M2w_TI',     'M2 weekly',      cM2w, '-',   0.7;  ...
  'M2m_TI',     'M2 monthly',     cM2m, '-',   0.7;  ...
  'M2q_TI',     'M2 quarterly',   cM2q, '-',   0.7;  ...
};

makeActualsGrid(data, paramKeys, paramLabels, scalings, qx, xTicks, xTickLbls, ...
  TI.series, false, 'TI — mean per quarter', ...
  fullfile(figDir, 'sensitivity_TI_actual.pdf'));

makeActualsGrid(data, paramKeys, paramLabels, scalings, qx, xTicks, xTickLbls, ...
  TI.series, true,  'TI — cumulative', ...
  fullfile(figDir, 'sensitivity_TI_actual_cum.pdf'));

% Box plots: pool errors of each method against benchmark, K x nPeriods
TI.boxBoth.methods = {'M1_TI','M2w_TI','M2m_TI','M2q_TI'};
TI.boxBoth.labels  = {'bonds-M1','bonds-M2w','bonds-M2m','bonds-M2q', ...
                      'bonds+BOM-M1','bonds+BOM-M2w','bonds+BOM-M2m','bonds+BOM-M2q'};
makeBoxGridDual(data, paramKeys, paramLabels, scalings, ...
  TI.boxBoth.methods, 'PAM_TI', 'PAM_TI_BOM', TI.boxBoth.labels, ...
  'TI — error distributions', ...
  fullfile(figDir, 'sensitivity_TI_errors_box.pdf'));

TI.kde.methods = {'M1_TI','M2w_TI','M2m_TI','M2q_TI'};
TI.kde.labels  = {'M1','M2 weekly','M2 monthly','M2 quarterly'};
TI.kde.colors  = {cM1, cM2w, cM2m, cM2q};
makeKdeGrid(data, paramKeys, paramLabels, scalings, ...
  TI.kde.methods, 'PAM_TI', TI.kde.labels, TI.kde.colors, ...
  'TI — error densities (PAM bonds benchmark)', ...
  fullfile(figDir, 'sensitivity_TI_errors_kde_bonds.pdf'));

makeKdeGrid(data, paramKeys, paramLabels, scalings, ...
  TI.kde.methods, 'PAM_TI_BOM', TI.kde.labels, TI.kde.colors, ...
  'TI — error densities (PAM bonds+BOM benchmark)', ...
  fullfile(figDir, 'sensitivity_TI_errors_kde_bom.pdf'));

makeStdHistGrid(data, paramKeys, paramLabels, scalings, ...
  TI.kde.methods, 'PAM_TI', TI.kde.labels, TI.kde.colors, ...
  'TI — quarterly std (PAM bonds)', ...
  fullfile(figDir, 'sensitivity_TI_std_hist_bonds.pdf'));

makeStdHistGrid(data, paramKeys, paramLabels, scalings, ...
  TI.kde.methods, 'PAM_TI_BOM', TI.kde.labels, TI.kde.colors, ...
  'TI — quarterly std (PAM bonds+BOM)', ...
  fullfile(figDir, 'sensitivity_TI_std_hist_bom.pdf'));

% =========================================================================
% SECTION 2 — TRANSLATION / OCI  (one benchmark only)
% =========================================================================
fprintf('Generating OCI figures...\n');

OCI.series = { ...
  'PAM_OCI', 'PAM',          cPAM, '-o', 1.0; ...
  'M1_OCI',  'M1',           cM1,  '-',  0.7; ...
  'M2w_OCI', 'M2 weekly',    cM2w, '-',  0.7; ...
  'M2m_OCI', 'M2 monthly',   cM2m, '-',  0.7; ...
  'M2q_OCI', 'M2 quarterly', cM2q, '-',  0.7; ...
};

makeActualsGrid(data, paramKeys, paramLabels, scalings, qx, xTicks, xTickLbls, ...
  OCI.series, false, 'OCI — mean per quarter', ...
  fullfile(figDir, 'sensitivity_OCI_actual.pdf'));

makeActualsGrid(data, paramKeys, paramLabels, scalings, qx, xTicks, xTickLbls, ...
  OCI.series, true,  'OCI — cumulative', ...
  fullfile(figDir, 'sensitivity_OCI_actual_cum.pdf'));

OCI.box.methods = {'M1_OCI','M2w_OCI','M2m_OCI','M2q_OCI'};
OCI.box.labels  = {'PAM-M1','PAM-M2w','PAM-M2m','PAM-M2q'};
makeBoxGrid(data, paramKeys, paramLabels, scalings, ...
  OCI.box.methods, 'PAM_OCI', OCI.box.labels, ...
  'OCI — error distributions', ...
  fullfile(figDir, 'sensitivity_OCI_errors_box.pdf'));

OCI.kde.methods = OCI.box.methods;
OCI.kde.labels  = {'M1','M2 weekly','M2 monthly','M2 quarterly'};
OCI.kde.colors  = {cM1, cM2w, cM2m, cM2q};
makeKdeGrid(data, paramKeys, paramLabels, scalings, ...
  OCI.kde.methods, 'PAM_OCI', OCI.kde.labels, OCI.kde.colors, ...
  'OCI — error densities', ...
  fullfile(figDir, 'sensitivity_OCI_errors_kde.pdf'));

makeStdHistGrid(data, paramKeys, paramLabels, scalings, ...
  OCI.kde.methods, 'PAM_OCI', OCI.kde.labels, OCI.kde.colors, ...
  'OCI — quarterly std', ...
  fullfile(figDir, 'sensitivity_OCI_std_hist.pdf'));

% =========================================================================
% SECTION 3 — CONSTANT CURRENCY (CC)
% =========================================================================
fprintf('Generating CC figures...\n');

CC.series = { ...
  'fBOM',     'PAM BOM',    cPAM,   '-o',  1.0;  ...
  'fBonds',   'PAM bonds',  cPAM,   '--s', 0.7;  ...
  'M1_CC',    'M1 CC',      cM1,    '-',   0.7;  ...
  'CC_avg',   'CC avg',     cCCavg, '-',   0.7;  ...
  'CC_close', 'CC close',   cCCcls, '-',   0.7;  ...
};

makeActualsGrid(data, paramKeys, paramLabels, scalings, ccQx, ccXTicks, ccXTickLbls, ...
  CC.series, false, 'CC — mean per quarter', ...
  fullfile(figDir, 'sensitivity_CC_actual.pdf'));

makeActualsGrid(data, paramKeys, paramLabels, scalings, ccQx, ccXTicks, ccXTickLbls, ...
  CC.series, true,  'CC — cumulative', ...
  fullfile(figDir, 'sensitivity_CC_actual_cum.pdf'));

CC.boxBoth.methods = {'M1_CC','CC_avg','CC_close'};
CC.boxBoth.labels  = {'BOM-M1','BOM-avg','BOM-close','bonds-M1','bonds-avg','bonds-close'};
makeBoxGridDual(data, paramKeys, paramLabels, scalings, ...
  CC.boxBoth.methods, 'fBOM', 'fBonds', CC.boxBoth.labels, ...
  'CC — error distributions', ...
  fullfile(figDir, 'sensitivity_CC_errors_box.pdf'));

CC.kde.methods = {'M1_CC','CC_avg','CC_close'};
CC.kde.labels  = {'M1 CC','CC avg','CC close'};
CC.kde.colors  = {cM1, cCCavg, cCCcls};
makeKdeGrid(data, paramKeys, paramLabels, scalings, ...
  CC.kde.methods, 'fBOM', CC.kde.labels, CC.kde.colors, ...
  'CC — error densities (PAM BOM benchmark)', ...
  fullfile(figDir, 'sensitivity_CC_errors_kde_bom.pdf'));

makeKdeGrid(data, paramKeys, paramLabels, scalings, ...
  CC.kde.methods, 'fBonds', CC.kde.labels, CC.kde.colors, ...
  'CC — error densities (PAM bonds benchmark)', ...
  fullfile(figDir, 'sensitivity_CC_errors_kde_bonds.pdf'));

makeStdHistGrid(data, paramKeys, paramLabels, scalings, ...
  CC.kde.methods, 'fBOM', CC.kde.labels, CC.kde.colors, ...
  'CC — quarterly std (PAM BOM)', ...
  fullfile(figDir, 'sensitivity_CC_std_hist_bom.pdf'));

makeStdHistGrid(data, paramKeys, paramLabels, scalings, ...
  CC.kde.methods, 'fBonds', CC.kde.labels, CC.kde.colors, ...
  'CC — quarterly std (PAM bonds)', ...
  fullfile(figDir, 'sensitivity_CC_std_hist_bonds.pdf'));

fprintf('\nAll figures saved to %s/\n', figDir);

end


% =========================================================================
% LOADING
% =========================================================================
function [data, paramKeys, paramLabels, scalings, K, nPeriods] = loadAllCheckpoints(ckptDir)
% Discover (paramKeys, scalings, K) from filenames; load all checkpoints.

files = dir(fullfile(ckptDir, '*_seed_*.mat'));
if isempty(files)
  error('No checkpoints found in %s', ckptDir);
end

paramKeysSet = {};
siSet  = [];
kSet   = [];

% Parse filenames like 'procLead_s3_seed_0017.mat'
tokRe = '^([A-Za-z]+)_s(\d+)_seed_(\d+)\.mat$';
parsed = cell(length(files), 1);
for f = 1:length(files)
  tok = regexp(files(f).name, tokRe, 'tokens', 'once');
  if isempty(tok), continue; end
  paramKey = tok{1};
  si  = str2double(tok{2});
  k   = str2double(tok{3});
  parsed{f} = {paramKey, si, k};
  if ~ismember(paramKey, paramKeysSet), paramKeysSet{end+1} = paramKey; end %#ok<AGROW>
  if ~ismember(si, siSet), siSet(end+1) = si; end %#ok<AGROW>
  if ~ismember(k, kSet),  kSet(end+1)  = k;  end %#ok<AGROW>
end

% Sort by canonical order (matches runSensitivity)
% bomBoth is the combined procLead+mfg sweep added in runSensitivity to
% test the "BOM-source-of-TI-gap" hypothesis. Listed last so it shows as
% the bottom row in every grid.
canonicalOrder = {'procLead','mfg','custPay','suppPay','bomBoth'};
paramKeys = canonicalOrder(ismember(canonicalOrder, paramKeysSet));
if length(paramKeys) ~= length(paramKeysSet)
  % Fall back: include unknown keys at the end
  extra = setdiff(paramKeysSet, paramKeys, 'stable');
  paramKeys = [paramKeys, extra(:)'];
end

% Labels matching runSensitivity's paramSweeps
labelMap = containers.Map( ...
  {'procLead','mfg','custPay','suppPay','bomBoth'}, ...
  {'Procurement lead time','Manufacturing time','Customer payment delay','Supplier payment delay','BOM phase (procLead + mfg)'});
paramLabels = cell(1, length(paramKeys));
for i = 1:length(paramKeys)
  if isKey(labelMap, paramKeys{i})
    paramLabels{i} = labelMap(paramKeys{i});
  else
    paramLabels{i} = paramKeys{i};
  end
end

% Scaling levels (canonical = [0 0.25 0.5 0.75 1] mapped to si = 1..5)
scalings = [0 0.25 0.5 0.75 1];
scalings = scalings(1:max(siSet));   % trim if fewer than 5 are present

nParams = length(paramKeys);
nScales = length(scalings);
K       = max(kSet);

% Pre-allocate cell array and load
data = cell(nParams, nScales, K);
nPeriods = 0;
for f = 1:length(files)
  if isempty(parsed{f}), continue; end
  paramKey = parsed{f}{1};
  si       = parsed{f}{2};
  k        = parsed{f}{3};
  pi       = find(strcmp(paramKeys, paramKey), 1);
  if isempty(pi) || si > nScales || k > K, continue; end
  tmp = load(fullfile(ckptDir, files(f).name), 'r');
  data{pi, si, k} = tmp.r;
  if nPeriods == 0 && isfield(tmp.r, 'PAM_TI')
    nPeriods = length(tmp.r.PAM_TI);
  end
end
end


% =========================================================================
% PER-CELL DATA EXTRACTION HELPERS
% =========================================================================
function M = stackField(data, pi, si, fieldName)
% Returns [K x nPeriods]; rows of all-NaN where data is missing.
[~, ~, K] = size(data);
% Find first non-empty to get nPeriods
nP = 0;
for k = 1:K
  if ~isempty(data{pi, si, k}) && isfield(data{pi, si, k}, fieldName)
    nP = length(data{pi, si, k}.(fieldName)); break;
  end
end
if nP == 0, M = []; return; end
M = nan(K, nP);
for k = 1:K
  r = data{pi, si, k};
  if isempty(r) || ~isfield(r, fieldName), continue; end
  v = r.(fieldName);
  if length(v) ~= nP, continue; end
  M(k, :) = v;
end
end


function v = meanQ(data, pi, si, fieldName)
% Mean over K of the per-quarter field; [1 x nPeriods]
M = stackField(data, pi, si, fieldName);
if isempty(M), v = []; return; end
v = mean(M, 1, 'omitnan');
end


% =========================================================================
% GRID PLOTTERS  (4 rows = params, 5 cols = scalings)
% =========================================================================
function makeActualsGrid(data, paramKeys, paramLabels, scalings, qx, xTicks, xTickLbls, ...
                         series, doCum, sgTitleText, outPath)
% Each panel: line per series. series = {fieldName, label, color, lineStyle, weight; ...}

nParams = length(paramKeys);
nScales = length(scalings);
fh = figure('Visible','on','WindowStyle','docked'); clf;
tl = tiledlayout(fh, nParams, nScales, 'Padding', 'compact', 'TileSpacing', 'compact');

handlesForLegend = [];
seriesLabels     = series(:, 2);

for pi = 1:nParams
  for si = 1:nScales
    ax = nexttile(tl, (pi-1)*nScales + si); hold(ax,'on');
    for s = 1:size(series, 1)
      v = meanQ(data, pi, si, series{s,1});
      if isempty(v), continue; end
      if doCum, v = cumsum(v, 'omitnan'); end
      h = plot(ax, qx, v/1e6, series{s,4}, ...
        'Color', series{s,3}, 'LineWidth', series{s,5}, ...
        'MarkerSize', 2, 'DisplayName', series{s,2});
      if pi == 1 && si == 1, handlesForLegend(end+1) = h; end %#ok<AGROW>
    end
    yline(ax, 0, 'k:', 'LineWidth', 0.5, 'HandleVisibility', 'off');
    set(ax, 'XTick', xTicks, 'XTickLabel', xTickLbls, 'XTickLabelRotation', 0, ...
            'FontSize', 6);
    grid(ax, 'on');
    title(ax, sprintf('%s, s=%.2f', paramKeys{pi}, scalings(si)), 'FontSize', 7);
    if si == 1, ylabel(ax, paramLabels{pi}, 'FontSize', 7); end
  end
end

sgtitle(fh, sgTitleText, 'FontSize', 11, 'FontWeight', 'bold');
if ~isempty(handlesForLegend)
  lg = legend(handlesForLegend, seriesLabels, 'Orientation', 'horizontal', ...
              'FontSize', 7, 'NumColumns', length(handlesForLegend));
  lg.Layout.Tile = 'south';
end
saveFig(fh, outPath, 32, 20);
end


function makeBoxGrid(data, paramKeys, paramLabels, scalings, methods, benchField, labels, ...
                     sgTitleText, outPath)
% Box plot of (method - benchmark) errors, per panel.

nParams = length(paramKeys);
nScales = length(scalings);
fh = figure('Visible','on','WindowStyle','docked'); clf;
tl = tiledlayout(fh, nParams, nScales, 'Padding', 'compact', 'TileSpacing', 'compact');

for pi = 1:nParams
  for si = 1:nScales
    ax = nexttile(tl, (pi-1)*nScales + si);
    err = collectErrors(data, pi, si, methods, benchField);
    if isempty(err)
      axis(ax, 'off'); continue;
    end
    boxplot(ax, err, 'Labels', labels, 'Symbol', '.');
    yline(ax, 0, 'k--', 'LineWidth', 0.4, 'HandleVisibility', 'off');
    set(ax, 'FontSize', 6, 'XTickLabelRotation', 90);
    grid(ax, 'on');
    title(ax, sprintf('%s, s=%.2f', paramKeys{pi}, scalings(si)), 'FontSize', 7);
    if si == 1, ylabel(ax, paramLabels{pi}, 'FontSize', 7); end
  end
end

sgtitle(fh, sgTitleText, 'FontSize', 11, 'FontWeight', 'bold');
saveFig(fh, outPath, 32, 20);
end


function makeBoxGridDual(data, paramKeys, paramLabels, scalings, methods, bench1, bench2, labels, ...
                         sgTitleText, outPath)
% Box plot with two benchmark groups side by side (matches runMC's TI/CC box).
% If one benchmark is missing (e.g., PAM_TI_BOM in pre-BOM-discount-fix
% checkpoints), the corresponding group columns are filled with NaN so
% the label count still matches the data column count.

nParams = length(paramKeys);
nScales = length(scalings);
nMethods = length(methods);
fh = figure('Visible','on','WindowStyle','docked'); clf;
tl = tiledlayout(fh, nParams, nScales, 'Padding', 'compact', 'TileSpacing', 'compact');

for pi = 1:nParams
  for si = 1:nScales
    ax = nexttile(tl, (pi-1)*nScales + si);
    e1 = collectErrors(data, pi, si, methods, bench1);
    e2 = collectErrors(data, pi, si, methods, bench2);
    if isempty(e1) && isempty(e2)
      axis(ax, 'off'); continue;
    end
    % Pad each block to nMethods columns so [e1 e2] always has 2*nMethods columns
    % matching the label count, regardless of which benchmark is missing.
    if isempty(e1)
      e1 = nan(size(e2, 1), nMethods);
    elseif isempty(e2)
      e2 = nan(size(e1, 1), nMethods);
    end
    % Align row counts if they differ (shouldn't, but be defensive)
    if size(e1, 1) ~= size(e2, 1)
      nRows = max(size(e1, 1), size(e2, 1));
      if size(e1, 1) < nRows, e1(end+1:nRows, :) = NaN; end
      if size(e2, 1) < nRows, e2(end+1:nRows, :) = NaN; end
    end
    boxplot(ax, [e1 e2], 'Labels', labels, 'Symbol', '.');
    yline(ax, 0, 'k--', 'LineWidth', 0.4, 'HandleVisibility', 'off');
    set(ax, 'FontSize', 6, 'XTickLabelRotation', 90);
    grid(ax, 'on');
    title(ax, sprintf('%s, s=%.2f', paramKeys{pi}, scalings(si)), 'FontSize', 7);
    if si == 1, ylabel(ax, paramLabels{pi}, 'FontSize', 7); end
  end
end

sgtitle(fh, sgTitleText, 'FontSize', 11, 'FontWeight', 'bold');
saveFig(fh, outPath, 36, 20);
end


function makeKdeGrid(data, paramKeys, paramLabels, scalings, methods, benchField, labels, colors, ...
                     sgTitleText, outPath)
% Silverman-bandwidth KDE of pooled errors per method, per panel.

nParams = length(paramKeys);
nScales = length(scalings);
fh = figure('Visible','on','WindowStyle','docked'); clf;
tl = tiledlayout(fh, nParams, nScales, 'Padding', 'compact', 'TileSpacing', 'compact');

handlesForLegend = [];

for pi = 1:nParams
  for si = 1:nScales
    ax = nexttile(tl, (pi-1)*nScales + si); hold(ax,'on');
    for m = 1:length(methods)
      Mmat = stackField(data, pi, si, methods{m});
      Bmat = stackField(data, pi, si, benchField);
      if isempty(Mmat) || isempty(Bmat) || ~isequal(size(Mmat), size(Bmat)), continue; end
      e = (Mmat - Bmat) / 1e6;
      e = e(:); e = e(~isnan(e));
      if length(e) < 5, continue; end
      s = std(e);
      if s == 0, continue; end
      h = 0.9 * min(s, iqr(e)/1.34) * length(e)^(-1/5);
      if h <= 0, continue; end
      [f, xi] = ksdensity(e, 'Bandwidth', h);
      ph = plot(ax, xi, f, 'Color', colors{m}, 'LineWidth', 0.8, 'DisplayName', labels{m});
      if pi == 1 && si == 1, handlesForLegend(end+1) = ph; end %#ok<AGROW>
    end
    xline(ax, 0, 'k--', 'LineWidth', 0.4, 'HandleVisibility', 'off');
    set(ax, 'FontSize', 6);
    grid(ax, 'on');
    title(ax, sprintf('%s, s=%.2f', paramKeys{pi}, scalings(si)), 'FontSize', 7);
    if si == 1, ylabel(ax, paramLabels{pi}, 'FontSize', 7); end
  end
end

sgtitle(fh, sgTitleText, 'FontSize', 11, 'FontWeight', 'bold');
if ~isempty(handlesForLegend)
  lg = legend(handlesForLegend, labels(1:length(handlesForLegend)), ...
              'Orientation', 'horizontal', 'FontSize', 7, ...
              'NumColumns', length(handlesForLegend));
  lg.Layout.Tile = 'south';
end
saveFig(fh, outPath, 32, 20);
end


function makeStdHistGrid(data, paramKeys, paramLabels, scalings, methods, benchField, labels, colors, ...
                         sgTitleText, outPath)
% Histogram of per-quarter std of errors (std across K iterations, per quarter).

nParams = length(paramKeys);
nScales = length(scalings);
fh = figure('Visible','on','WindowStyle','docked'); clf;
tl = tiledlayout(fh, nParams, nScales, 'Padding', 'compact', 'TileSpacing', 'compact');

handlesForLegend = [];

for pi = 1:nParams
  for si = 1:nScales
    ax = nexttile(tl, (pi-1)*nScales + si); hold(ax,'on');
    for m = 1:length(methods)
      Mmat = stackField(data, pi, si, methods{m});
      Bmat = stackField(data, pi, si, benchField);
      if isempty(Mmat) || isempty(Bmat) || ~isequal(size(Mmat), size(Bmat)), continue; end
      e = (Mmat - Bmat) / 1e6;
      perQStd = std(e, 0, 1, 'omitnan');
      perQStd = perQStd(~isnan(perQStd));
      if isempty(perQStd), continue; end
      [counts, edges] = histcounts(perQStd, 10);
      ph = stairs(ax, [edges(1:end-1), edges(end)], [counts, 0], ...
        'Color', colors{m}, 'LineWidth', 1.0, 'DisplayName', labels{m});
      if pi == 1 && si == 1, handlesForLegend(end+1) = ph; end %#ok<AGROW>
    end
    set(ax, 'FontSize', 6);
    grid(ax, 'on');
    title(ax, sprintf('%s, s=%.2f', paramKeys{pi}, scalings(si)), 'FontSize', 7);
    if si == 1, ylabel(ax, paramLabels{pi}, 'FontSize', 7); end
  end
end

sgtitle(fh, sgTitleText, 'FontSize', 11, 'FontWeight', 'bold');
if ~isempty(handlesForLegend)
  lg = legend(handlesForLegend, labels(1:length(handlesForLegend)), ...
              'Orientation', 'horizontal', 'FontSize', 7, ...
              'NumColumns', length(handlesForLegend));
  lg.Layout.Tile = 'south';
end
saveFig(fh, outPath, 32, 20);
end


% =========================================================================
% UTILITIES
% =========================================================================
function E = collectErrors(data, pi, si, methods, benchField)
% Concatenate (method - benchmark) errors across methods into a [N x nMethods]
% matrix where rows are pooled K*nPeriods observations. Returns [] if empty.
Bmat = stackField(data, pi, si, benchField);
if isempty(Bmat), E = []; return; end
nMethods = length(methods);
cols = cell(1, nMethods);
nObs = numel(Bmat);
for m = 1:nMethods
  Mmat = stackField(data, pi, si, methods{m});
  if isempty(Mmat) || ~isequal(size(Mmat), size(Bmat))
    cols{m} = nan(nObs, 1);
  else
    e = (Mmat - Bmat) / 1e6;
    cols{m} = e(:);
  end
end
E = [cols{:}];
end


function [ticks, lbls] = yearTicks(nPeriods)
% Sparse x-axis ticks every 4 quarters (= 1 year), labels every 5 years.
ticks = 1:4:nPeriods;
lbls  = repmat({''}, 1, length(ticks));
% Assume simulation starts at year 2007 (matches runSensitivity default)
for i = 1:length(ticks)
  yr = 2007 + (i - 1);
  if mod(yr, 5) == 0 || i == 1 || i == length(ticks)
    lbls{i} = num2str(yr);
  end
end
end


function saveFig(fh, outPath, wcm, hcm)
% Save to PDF at requested cm size. Figures are docked so all 19 appear as
% tabs in a single MATLAB Figures container; we keep them open so the user
% can flip between them.
set(fh, 'PaperUnits', 'centimeters', 'PaperSize', [wcm hcm], ...
        'PaperPosition', [0 0 wcm hcm], 'PaperPositionMode', 'manual');
% Title the docked tab with the chart name (last part of the path, no extension)
[~, baseName] = fileparts(outPath);
set(fh, 'Name', baseName, 'NumberTitle', 'off');
saveas(fh, outPath);
fprintf('  saved: %s\n', outPath);
end
