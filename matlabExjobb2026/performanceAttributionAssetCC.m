function fcc = performanceAttributionAssetCC(dm, dc, dp, pnl, window)
% performanceAttributionAssetCC
%   PAM constant-currency benchmark computed by walking PAM's asset
%   framework directly. Rolling per-day PY anchor (current month minus
%   12 months) is the only anchor convention. Two scopes are returned:
%
%     fcc.bonds.{trans,transl,cross,total}_{monthly,quarterly}
%         restricted to dc.assets.indBond (AR + AP zero coupon bonds)
%     fcc.BOM.{trans,transl,cross,total}_{monthly,quarterly}
%         restricted to dc.assets.indBond + dc.assets.indManufactured
%
%   The benchmark is conceptually computed as two parallel SEK
%   valuations of each in-scope asset over its lifetime:
%     V_actual_j(t) = X_j(t) * f_{c_j, c^F}(t) * f_{c^F, c^P}(t)
%     V_const_j(t)  = X_j(t) * fRoll_{c_j, c^F}(t) * fRoll_{c^F, c^P}(t)
%   where fRoll(t) is the prior-year same-calendar-month average
%   updated daily with the current month. The Setup A three-way
%   decomposition (trans/transl/cross) is applied per asset per day.
%
%   X_j(t) is the asset's foreign-currency face-equivalent value,
%   extracted from PAM's pricing output:
%     bonds (pricing currency = cash-flow currency):
%       X_j(t) = hI(t, j) * Pbar(t, j)
%     BOMs (pricing currency = functional EUR):
%       X_j(t) = hI(t, j) * Pbar(t, j) / fx{c_j, c^F}(t)
%   Cash-flow sign is carried automatically by hI (positive for
%   receivables/Product BOMs, negative for payables/Component BOMs).
%
%   The maturity-day pull-to-par is captured by extending each asset's
%   integration window to its cash-flow date and setting X at par
%   (undiscounted face), equivalent to PAM's dVhDdf_arApBonds term
%   in the full-portfolio CC.
%
% Inputs:
%   dm     market data
%   dc     company data (assets, b, p, a, ap, sa, productNumbers,
%                       productOrderDate, etc.)
%   dp     PA primitives (dp.Pbar, dp.IC, dp.hI0, dp.xBI, dp.xSI)
%   pnl    PnL struct (pnl.quarterStartIdx, pnl.quarterEndIdx)
%   window 'month' (default) | 'quarter' | 'week'
%
% Output struct fields:
%   fcc.bonds.{trans,transl,cross,total}_{monthly,quarterly}
%   fcc.BOM.{trans,transl,cross,total}_{monthly,quarterly}
%   fcc.subEndDates, fcc.periodEndDates, fcc.window
%
% Defensibility: all asset values come from PAM's existing pricing
% engine (clsPriceBond, clsPriceBOM via dp.Pbar). The Setup A three-way
% decomposition is PAM's. No new pricing or discounting is introduced.

if nargin < 5 || isempty(window), window = 'month'; end

% =========================================================================
% Early input validation — fail loudly if inputs are malformed
% =========================================================================
assert(isfield(pnl, 'quarterStartIdx') && ~isempty(pnl.quarterStartIdx), ...
  'performanceAttributionAssetCC: pnl.quarterStartIdx missing or empty');
assert(isfield(pnl, 'quarterEndIdx') && ~isempty(pnl.quarterEndIdx), ...
  'performanceAttributionAssetCC: pnl.quarterEndIdx missing or empty');
assert(isfield(dc, 'assets') && isfield(dc.assets, 'indBond'), ...
  'performanceAttributionAssetCC: dc.assets.indBond missing');
assert(isfield(dp, 'Pbar') && ~isempty(dp.Pbar), ...
  'performanceAttributionAssetCC: dp.Pbar missing or empty');

% =========================================================================
% Setup
% =========================================================================
M    = length(dm.dates);
nCur = length(dm.cName);
iEUR = find(strcmp(dm.cName, 'EUR'));
iSEK = find(strcmp(dm.cName, 'SEK'));
f_EUR_SEK = dm.fx{iEUR, iSEK};

% Reconstruct hI from dp (same formula as performanceAttribution.m line 16)
N  = length(dc.assets.assets);
hI = [dp.hI0 ; repmat(dp.hI0, M-1, 1) + cumsum(dp.xBI(2:end,:) - dp.xSI(2:end,:))];
activeAssets = (sum(abs(hI), 1) ~= 0)';

% =========================================================================
% Sub-period grid + per-sub-period FX averages + PY same-month index
% =========================================================================
[sStart, sEnd] = buildSubPeriodGrid(dm.dates, window);
nSub = length(sStart);
d2s = zeros(M, 1);
for s = 1:nSub
  d2s(sStart(s):sEnd(s)) = s;
end

avgFor_EUR = zeros(nSub, nCur);
for c = 1:nCur
  if c == iEUR || c == iSEK, continue; end
  fxCEUR = dm.fx{c, iEUR};
  if isempty(fxCEUR), continue; end
  for s = 1:nSub
    v = fxCEUR(sStart(s):sEnd(s));
    good = ~isnan(v);
    if any(good), avgFor_EUR(s, c) = mean(v(good)); end
  end
end

avgEUR_SEK = zeros(nSub, 1);
for s = 1:nSub
  v = f_EUR_SEK(sStart(s):sEnd(s));
  good = ~isnan(v);
  if any(good), avgEUR_SEK(s) = mean(v(good)); end
end

compIdx = findComparisonPeriod(dm.dates, sStart, d2s);

% =========================================================================
% Per-day rolling PY anchors (current calendar month minus 12)
% =========================================================================
f_for_roll = cell(nCur, 1);
for c = 1:nCur
  f_for_roll{c} = zeros(M, 1);
end
f_EUR_SEK_roll = zeros(M, 1);

for t = 1:M
  s_t = d2s(t);
  if s_t == 0, continue; end
  c_s = compIdx(s_t);
  if c_s == 0, continue; end
  for c = 1:nCur
    if c == iEUR || c == iSEK, continue; end
    f_for_roll{c}(t) = avgFor_EUR(c_s, c);
  end
  f_EUR_SEK_roll(t) = avgEUR_SEK(c_s);
end

% =========================================================================
% Scope masks (intersected with active assets)
% =========================================================================
mask_bonds = false(N, 1);
mask_BOM   = false(N, 1);
mask_bonds(dc.assets.indBond)         = true;
mask_BOM(dc.assets.indBond)           = true;
mask_BOM(dc.assets.indManufactured)   = true;
mask_bonds = mask_bonds & activeAssets;
mask_BOM   = mask_BOM   & activeAssets;

% =========================================================================
% Accumulators: 2 scopes × 3 components (total derived as sum)
% =========================================================================
trans_bonds_m  = zeros(nSub, 1);  transl_bonds_m  = zeros(nSub, 1);  cross_bonds_m  = zeros(nSub, 1);
trans_BOM_m    = zeros(nSub, 1);  transl_BOM_m    = zeros(nSub, 1);  cross_BOM_m    = zeros(nSub, 1);

% =========================================================================
% Per-asset walk
% =========================================================================
for j = 1:N
  if ~(mask_bonds(j) || mask_BOM(j)), continue; end

  % Lifetime
  alive = hI(:, j) ~= 0;
  if ~any(alive), continue; end
  t_birth = find(alive, 1, 'first');
  t_death = find(alive, 1, 'last');
  if t_birth >= M || t_death <= 1 || t_birth > t_death, continue; end

  % Foreign-currency exposure
  asset = dc.assets.assets{j};
  if isa(asset, 'clsPriceBond')
    iCurFor = asset.iCurCf(1);
  elseif isa(asset, 'clsPriceBOM')
    iCurFor = asset.iCurK(1);
  else
    continue;
  end
  if iCurFor == iSEK, continue; end
  iCurIC = dp.IC(j);

  % X(t) such that X × fx{iCurFor, SEK} = SEK value of asset
  a_path = dm.fx{iCurFor, iEUR};
  if isempty(a_path), continue; end
  if iCurIC == iCurFor
    X_full = hI(:, j) .* dp.Pbar(:, j);
  else
    fxICtoEUR = dm.fx{iCurIC, iEUR};
    if isempty(fxICtoEUR), continue; end
    X_full = hI(:, j) .* dp.Pbar(:, j) .* fxICtoEUR ./ a_path;
  end

  % ---- Maturity-day pull-to-par extension --------------------------------
  % hI drops to 0 on the asset's cfDate (after SELL netting); extend the
  % integration window to t_pay and set X(t_pay) to the foreign-currency
  % face at par (undiscounted), preserving the original sign of hI.
  if isa(asset, 'clsPriceBond')
    cf_max = max(asset.cfDates(:));
  else  % clsPriceBOM
    cf_max = max(asset.KDates(:));
  end
  t_pay = find(dm.dates >= cf_max, 1, 'first');
  if ~isempty(t_pay) && t_pay > t_death && t_pay <= M
    parFace = hI(t_death, j);   % bond: ±notional with correct sign
    if isa(asset, 'clsPriceBond')
      X_full(t_pay) = parFace;
    else  % clsPriceBOM
      X_full(t_pay) = sign(parFace) * abs(parFace) * abs(asset.K(end)) * sign(asset.K(end));
    end
    t_death = t_pay;
  end

  t_window = (t_birth:t_death)';
  X = X_full(t_window);
  a = a_path(t_window);
  b = f_EUR_SEK(t_window);

  if any(~isfinite(X)) || any(~isfinite(a)) || any(~isfinite(b)), continue; end

  buckets = d2s(t_window);
  validBk = buckets > 0;
  if ~any(validBk), continue; end

  % Per-day rolling anchor arrays
  aRoll = f_for_roll{iCurFor}(t_window);
  bRoll = f_EUR_SEK_roll(t_window);
  rollValid = (aRoll > 0) & (bRoll > 0);
  if ~any(rollValid), continue; end

  % Compute F functions with rolling anchor (per-day)
  F_tr = X .* bRoll .* (a - aRoll);
  F_tl = X .* aRoll .* (b - bRoll);
  F_cr = X .* (a - aRoll) .* (b - bRoll);
  F_tr(~rollValid) = 0;
  F_tl(~rollValid) = 0;
  F_cr(~rollValid) = 0;
  d_tr = [F_tr(1); diff(F_tr)];
  d_tl = [F_tl(1); diff(F_tl)];
  d_cr = [F_cr(1); diff(F_cr)];

  if mask_bonds(j)
    trans_bonds_m  = trans_bonds_m  + accumarray(buckets(validBk), d_tr(validBk),  [nSub, 1]);
    transl_bonds_m = transl_bonds_m + accumarray(buckets(validBk), d_tl(validBk), [nSub, 1]);
    cross_bonds_m  = cross_bonds_m  + accumarray(buckets(validBk), d_cr(validBk),  [nSub, 1]);
  end
  if mask_BOM(j)
    trans_BOM_m  = trans_BOM_m  + accumarray(buckets(validBk), d_tr(validBk),  [nSub, 1]);
    transl_BOM_m = transl_BOM_m + accumarray(buckets(validBk), d_tl(validBk), [nSub, 1]);
    cross_BOM_m  = cross_BOM_m  + accumarray(buckets(validBk), d_cr(validBk),  [nSub, 1]);
  end
end

% =========================================================================
% Pack output struct (monthly)
% =========================================================================
fcc.bonds.trans_monthly  = trans_bonds_m;
fcc.bonds.transl_monthly = transl_bonds_m;
fcc.bonds.cross_monthly  = cross_bonds_m;
fcc.bonds.total_monthly  = trans_bonds_m + transl_bonds_m + cross_bonds_m;

fcc.BOM.trans_monthly    = trans_BOM_m;
fcc.BOM.transl_monthly   = transl_BOM_m;
fcc.BOM.cross_monthly    = cross_BOM_m;
fcc.BOM.total_monthly    = trans_BOM_m + transl_BOM_m + cross_BOM_m;

% =========================================================================
% Quarterly aggregation
% =========================================================================
qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;
Q      = length(qStart);

% Always create all 8 quarterly fields, even if Q=0 (defensive)
scopes  = {'bonds', 'BOM'};
fields  = {'trans', 'transl', 'cross', 'total'};
for si = 1:length(scopes)
  for fi = 1:length(fields)
    fname_m = [fields{fi} '_monthly'];
    fname_q = [fields{fi} '_quarterly'];
    if Q == 0
      fcc.(scopes{si}).(fname_q) = zeros(0, 1);
    else
      fcc.(scopes{si}).(fname_q) = aggToQ(fcc.(scopes{si}).(fname_m), sEnd, qStart, qEnd, Q);
    end
  end
end

assert(Q > 0, ...
  'performanceAttributionAssetCC: Q=0 (pnl.quarterStartIdx is empty), no quarterly output produced');

% =========================================================================
% Sanity asserts: trans + transl + cross = total per scope
% =========================================================================
ccScale = max([abs(fcc.bonds.total_quarterly); abs(fcc.BOM.total_quarterly)]) + 1;
for si = 1:length(scopes)
  s = scopes{si};
  decompErr = max(abs(fcc.(s).trans_quarterly + fcc.(s).transl_quarterly + ...
                      fcc.(s).cross_quarterly  - fcc.(s).total_quarterly));
  assert(decompErr < 1e-6 * ccScale, ...
    'PAM-asset %s: trans + transl + cross != total (max err = %.3g)', s, decompErr);
end

% =========================================================================
% Metadata
% =========================================================================
fcc.subEndDates    = dm.dates(sEnd);
fcc.periodEndDates = dm.dates(qEnd);
fcc.window         = window;

end


%% =========================================================================
function v = aggToQ(monthly, sEnd, qStart, qEnd, Q)
v = zeros(Q, 1);
for q = 1:Q
  mask = (sEnd >= qStart(q)) & (sEnd <= qEnd(q));
  v(q) = sum(monthly(mask));
end
end


%% =========================================================================
function [sStart, sEnd] = buildSubPeriodGrid(dates, window)
M = length(dates);
[Y, Mo, ~] = datevec(dates);
Y = Y(:); Mo = Mo(:);
switch lower(window)
  case 'month'
    key = Y * 100 + Mo;
  case 'quarter'
    key = Y * 10 + floor((Mo - 1) / 3) + 1;
  case 'week'
    refMon = datenum(1970, 1, 5);
    key    = floor((dates(:) - refMon) / 7);
  otherwise
    error('performanceAttributionAssetCC:badWindow', ...
      'window must be ''week'', ''month'', or ''quarter''.');
end
changes = [1; find(diff(key) ~= 0) + 1];
sStart  = changes;
sEnd    = [changes(2:end) - 1; M];
end


%% =========================================================================
function compIdx = findComparisonPeriod(dates, sStart, d2s)
nSub    = length(sStart);
compIdx = zeros(nSub, 1);
[Y, Mo, D] = datevec(dates);
for s = 1:nSub
  t = sStart(s);
  targetDate = datenum(Y(t) - 1, Mo(t), min(D(t), 28));
  ti = find(dates <= targetDate, 1, 'last');
  if isempty(ti), continue; end
  compIdx(s) = d2s(ti);
end
end
