function fcc = performanceAttributionFlowCC(dm, dc, pnl, window, useDiscounting)
% performanceAttributionFlowCC
%   Flow-restricted PAM CC, three lifecycle variants in one call.
%
%   Walks the same flow universe industry CC sees (AR + AP, transactionCode
%   == 10) and computes the PAM three-way decomposition (trans / transl /
%   cross) under three different exposure-window + PY-anchor pairings.
%
%   Each variant pairs its integration window with a PY frozen anchor at
%   the start of that window. Bonds anchors at t_rec; BOM anchors at t_ord.
%   This anchor-and-window pairing means bonds and BOM measure substantively
%   different things — their per-event cumulatives are NOT forced to be
%   equal (unlike an earlier version of this code that anchored both at
%   t_rec).
%
%     fcc.snap   — recognition-day snapshot.
%                  Single-day decomposition at t_rec, anchored at t_rec's PY.
%                  Algebraically equal to industry M1 CC^trans, but with the
%                  cross term split out.
%
%     fcc.bonds  — recognition-to-payment lifecycle, t_rec-anchored.
%                  Daily PAM diff() machinery applied from t_rec to t_pay
%                  using PY rates from t_rec's same-PY-month. Captures the
%                  FX path during the AR/AP holding period (industry's
%                  dI_FU + dI_FR analog, in CC framing with three-way split).
%                  Per-event cumulative = F_bonds(t_pay).
%
%     fcc.BOM    — order-to-payment lifecycle, t_ord-anchored.
%                  Daily PAM diff() machinery applied from t_ord to t_pay
%                  using PY rates from t_ord's same-PY-month (NOT t_rec's).
%                  Measures "deviation from PY rates at order month" across
%                  the entire economic commitment window from order date
%                  through payment date. Captures FX exposure that industry
%                  CC structurally misses — both the pre-recognition window
%                  AND the use of an order-month PY baseline.
%                  Per-event cumulative = F_BOM(t_pay) using t_ord's PY anchor.
%
%   Per-event PY rates (frozen for the entire lifecycle of the event):
%     a_PY     = avg of fx{c, EUR} over PY same calendar month of t_rec
%     b_PY     = avg of fx{EUR, SEK} over PY same calendar month of t_rec
%     a_PY_ord = avg of fx{c, EUR} over PY same calendar month of t_ord
%     b_PY_ord = avg of fx{EUR, SEK} over PY same calendar month of t_ord
%
%   bonds and snap use (a_PY, b_PY); BOM uses (a_PY_ord, b_PY_ord).
%
%   Daily decomposition (running CC at end of day t, against the relevant
%   anchor a_REF, b_REF):
%     F_trans(t)  = C * b_REF * (a(t) - a_REF)
%     F_transl(t) = C * a_REF * (b(t) - b_REF)
%     F_cross(t)  = C * (a(t) - a_REF) * (b(t) - b_REF)
%     F_total(t)  = C * (a(t)*b(t) - a_REF*b_REF)
%                = F_trans + F_transl + F_cross  (identity)
%
%   Daily contribution at day t = F_*(t) - F_*(t-1), with F_*(t_start - 1)
%   defined as 0 (the position did not exist before t_start). Each daily
%   contribution is bucketed into the sub-period containing day t.
%
%   If t_ord's PY data is unavailable (e.g., t_ord falls in the first year
%   of market data), BOM mode is skipped for that event while snap and bonds
%   are still computed normally.
%
% Inputs:
%   dm              market data (uses dm.dates, dm.cName, dm.fx, optionally dm.d)
%   dc              company data (uses dc.a, dc.ap, dc.sa, dc.p,
%                                 dc.productNumbers, dc.productOrderDate)
%   pnl             P&L struct (uses pnl.quarterStartIdx, pnl.quarterEndIdx)
%   window          'month' (default) | 'quarter' | 'week'
%   useDiscounting  true (default)  — value flows as discounted ZCB PVs:
%                                     C × d_{c,t}(T-t) × FX. Each daily F is
%                                     multiplied by the bond's discount factor
%                                     before computing daily diffs, so the CC
%                                     time profile reflects PV growth as the
%                                     bond pulls to par. Internally consistent
%                                     with the rest of PAM (ZCB-based).
%                                     Requires dm.d{c}.
%                   false           — value flows at face × FX (matches
%                                     industry CC convention without
%                                     discounting). Available as a diagnostic
%                                     to isolate face-vs-PV from other errors.
%
% Output struct fields:
%   fcc.snap.{trans,transl,cross,total}_{monthly,quarterly}
%   fcc.bonds.{trans,transl,cross,total}_{monthly,quarterly}
%   fcc.BOM.{trans,transl,cross,total}_{monthly,quarterly}
%   fcc.subEndDates    [nSub x 1]
%   fcc.periodEndDates [Q x 1]
%   fcc.window         string

if nargin < 4 || isempty(window), window = 'month'; end
if nargin < 5 || isempty(useDiscounting), useDiscounting = true; end

% =========================================================================
% Setup: dates, currency indices, FX paths
% =========================================================================
M    = length(dm.dates);
nCur = length(dm.cName);
iEUR = find(strcmp(dm.cName, 'EUR'));
iSEK = find(strcmp(dm.cName, 'SEK'));
f_EUR_SEK = dm.fx{iEUR, iSEK};

% =========================================================================
% Sub-period grid + day-to-sub-period lookup
% =========================================================================
[sStart, sEnd] = buildSubPeriodGrid(dm.dates, window);
nSub = length(sStart);
d2s = zeros(M, 1);
for s = 1:nSub
  d2s(sStart(s):sEnd(s)) = s;
end

% =========================================================================
% Per-sub-period averages of c->EUR and EUR->SEK rates
% =========================================================================
avgFor_EUR = zeros(nSub, nCur);
for c = 1:nCur
  if c == iEUR || c == iSEK, continue; end
  fxCEUR = dm.fx{c, iEUR};
  if isempty(fxCEUR), continue; end
  for s = 1:nSub
    v    = fxCEUR(sStart(s):sEnd(s));
    good = ~isnan(v);
    if any(good), avgFor_EUR(s, c) = mean(v(good)); end
  end
end

avgEUR_SEK = zeros(nSub, 1);
for s = 1:nSub
  v    = f_EUR_SEK(sStart(s):sEnd(s));
  good = ~isnan(v);
  if any(good), avgEUR_SEK(s) = mean(v(good)); end
end

% =========================================================================
% Comparison-period index (PY same calendar month, 12 months back)
% =========================================================================
compIdx = findComparisonPeriod(dm.dates, sStart, d2s);

% =========================================================================
% Build invoice-number lookups for order/payment dates
%   AR: invoiceNumber -> (orderDate, payDate)
%       orderDate via dc.sa.invoiceNumber -> dc.sa.itemNumber -> productIdx
%                  -> dc.productOrderDate(productIdx)
%       payDate  via matching transactionCode == 20 row in dc.a
%
%   AP: invoiceNumber -> (orderDate, payDate)
%       orderDate via dc.p.purchaseOrderNumber == ap.invoiceNumber
%                  -> dc.p.orderDate
%       payDate  via matching transactionCode == 20 row in dc.ap
% =========================================================================
[arOrderDateByInv, arPayDateByInv] = buildARLookups(dc);
[apOrderDateByInv, apPayDateByInv] = buildAPLookups(dc);

% =========================================================================
% Accumulator arrays (3 modes x 3 components, monthly buckets)
%   snap   : single-day deviation at t_rec, anchored at t_rec's PY
%   bonds  : daily F over [t_rec, t_pay], anchored at t_rec's PY,
%            cumulative = F(t_pay) under the t_rec-PY anchor
%   BOM    : daily F over [t_ord, t_pay], anchored at t_ord's PY,
%            cumulative = F(t_pay) under the t_ord-PY anchor (generally
%            NOT equal to the bonds cumulative because the anchors differ)
% =========================================================================
trans_snap_m   = zeros(nSub, 1);  transl_snap_m   = zeros(nSub, 1);  cross_snap_m   = zeros(nSub, 1);
trans_bonds_m  = zeros(nSub, 1);  transl_bonds_m  = zeros(nSub, 1);  cross_bonds_m  = zeros(nSub, 1);
trans_BOM_m    = zeros(nSub, 1);  transl_BOM_m    = zeros(nSub, 1);  cross_BOM_m    = zeros(nSub, 1);

% =========================================================================
% Walk AR (sales, sign +1)
% =========================================================================
arRows10 = find(dc.a.transactionCode == 10);
for k = 1:length(arRows10)
  r      = arRows10(k);
  c      = dc.a.iCur(r);
  if c == iSEK, continue; end
  C      = dc.a.foreignCurrencyAmount(r);
  invNum = dc.a.invoiceNumber(r);

  t_rec = dateToIdx(dm.dates, dc.a.accountingDate(r));
  t_pay = lookupDateIdx(arPayDateByInv, invNum, dm.dates);
  t_ord = lookupDateIdx(arOrderDateByInv, invNum, dm.dates);

  [trans_snap_m, transl_snap_m, cross_snap_m, ...
   trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
   trans_BOM_m,  transl_BOM_m,  cross_BOM_m] = ...
    addEvent(c, iEUR, +1, C, t_rec, t_pay, t_ord, ...
             dm, f_EUR_SEK, d2s, compIdx, avgFor_EUR, avgEUR_SEK, nSub, M, ...
             useDiscounting, ...
             trans_snap_m, transl_snap_m, cross_snap_m, ...
             trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
             trans_BOM_m,  transl_BOM_m,  cross_BOM_m);
end

% =========================================================================
% Walk AP (procurement, sign -1)
% =========================================================================
apRows10 = find(dc.ap.transactionCode == 10);
for k = 1:length(apRows10)
  r      = apRows10(k);
  c      = dc.ap.iCur(r);
  if c == iSEK, continue; end
  C      = dc.ap.foreignCurrencyAmount(r);
  invNum = dc.ap.invoiceNumber(r);

  t_rec = dateToIdx(dm.dates, dc.ap.accountingDate(r));
  t_pay = lookupDateIdx(apPayDateByInv, invNum, dm.dates);
  t_ord = lookupDateIdx(apOrderDateByInv, invNum, dm.dates);

  [trans_snap_m, transl_snap_m, cross_snap_m, ...
   trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
   trans_BOM_m,  transl_BOM_m,  cross_BOM_m] = ...
    addEvent(c, iEUR, -1, C, t_rec, t_pay, t_ord, ...
             dm, f_EUR_SEK, d2s, compIdx, avgFor_EUR, avgEUR_SEK, nSub, M, ...
             useDiscounting, ...
             trans_snap_m, transl_snap_m, cross_snap_m, ...
             trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
             trans_BOM_m,  transl_BOM_m,  cross_BOM_m);
end

% =========================================================================
% Pack into output struct, monthly first
% =========================================================================
fcc.snap.trans_monthly   = trans_snap_m;
fcc.snap.transl_monthly  = transl_snap_m;
fcc.snap.cross_monthly   = cross_snap_m;
fcc.snap.total_monthly   = trans_snap_m + transl_snap_m + cross_snap_m;

fcc.bonds.trans_monthly  = trans_bonds_m;
fcc.bonds.transl_monthly = transl_bonds_m;
fcc.bonds.cross_monthly  = cross_bonds_m;
fcc.bonds.total_monthly  = trans_bonds_m + transl_bonds_m + cross_bonds_m;

fcc.BOM.trans_monthly    = trans_BOM_m;
fcc.BOM.transl_monthly   = transl_BOM_m;
fcc.BOM.cross_monthly    = cross_BOM_m;
fcc.BOM.total_monthly    = trans_BOM_m + transl_BOM_m + cross_BOM_m;

% =========================================================================
% Quarterly aggregation (same convention as computeCC's aggToQtrs)
% =========================================================================
qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;
Q      = length(qStart);

modes  = {'snap', 'bonds', 'BOM'};
fields = {'trans', 'transl', 'cross', 'total'};
for mi = 1:length(modes)
  for fi = 1:length(fields)
    fname_m = [fields{fi} '_monthly'];
    fname_q = [fields{fi} '_quarterly'];
    fcc.(modes{mi}).(fname_q) = aggToQ(fcc.(modes{mi}).(fname_m), sEnd, qStart, qEnd, Q);
  end
end

% =========================================================================
% Sanity asserts
% =========================================================================
ccScale = max([abs(fcc.snap.total_quarterly); abs(fcc.bonds.total_quarterly); ...
               abs(fcc.BOM.total_quarterly)]) + 1;

for mi = 1:length(modes)
  m = modes{mi};
  decompErr = max(abs(fcc.(m).trans_quarterly + fcc.(m).transl_quarterly + ...
                      fcc.(m).cross_quarterly  - fcc.(m).total_quarterly));
  assert(decompErr < 1e-6 * ccScale, ...
    'PAM-flow %s: trans + transl + cross != total (max err = %.3g)', m, decompErr);
end

% NOTE: bonds and BOM cumulatives are NOT forced equal. Bonds anchors at
% t_rec's PY; BOM anchors at t_ord's PY. With different anchors the two
% modes measure substantively different things, and their per-event
% cumulatives generally differ. The earlier algebraic identity (bonds ==
% BOM) only held when both anchored at t_rec (a setup that made BOM
% reduce to "bonds with different timing buckets"); under the current
% anchor-and-window pairing it no longer applies.

% =========================================================================
% Metadata
% =========================================================================
fcc.subEndDates    = dm.dates(sEnd);
fcc.periodEndDates = dm.dates(qEnd);
fcc.window         = window;

end


%% =========================================================================
function [trans_snap_m, transl_snap_m, cross_snap_m, ...
          trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
          trans_BOM_m,  transl_BOM_m,  cross_BOM_m] = ...
    addEvent(c, iEUR, signFlow, C, t_rec, t_pay, t_ord, ...
             dm, f_EUR_SEK, d2s, compIdx, avgFor_EUR, avgEUR_SEK, nSub, M, ...
             useDiscounting, ...
             trans_snap_m, transl_snap_m, cross_snap_m, ...
             trans_bonds_m, transl_bonds_m, cross_bonds_m, ...
             trans_BOM_m,  transl_BOM_m,  cross_BOM_m)
% Apply this event's contributions to the three mode accumulators
% (snap, bonds, BOM). Snap and bonds anchor at t_rec's PY; BOM anchors
% at t_ord's PY (so its anchor matches the start of its integration window).

% --- Date validity ---
if isempty(t_rec) || isempty(t_pay), return; end
if isempty(t_ord), t_ord = t_rec; end                    % fall back if order date unknown
if t_rec < 1 || t_rec > M, return; end
if t_pay < 1 || t_pay > M, return; end
t_ord = max(min(t_ord, t_rec), 1);                       % clamp: order <= rec, >= 1

% --- Sub-period and PY comparison (recognition-month anchor for snap/bonds) ---
s_rec = d2s(t_rec);
if s_rec == 0, return; end
sc = compIdx(s_rec);
if sc == 0, return; end                                  % first year, no PY data

% --- Fixed-per-event PY rates (using recognition month's PY) — for snap and bonds ---
if c == iEUR
  a_PY = 1;
else
  a_PY = avgFor_EUR(sc, c);
end
b_PY = avgEUR_SEK(sc);
if a_PY == 0 || b_PY == 0, return; end

% --- PY rates anchored at the ORDER month — for BOM mode ---
% BOM integrates over [t_ord, t_pay], so we anchor its PY baseline at
% t_ord's same-PY-month rather than t_rec's. If t_ord's PY is unavailable
% (e.g., t_ord falls in the first year of market data and has no PY
% comparison period), BOM is skipped for this event while snap and bonds
% are still processed normally.
s_ord = d2s(t_ord);
if s_ord > 0
  sc_ord = compIdx(s_ord);
else
  sc_ord = 0;
end
bomPYavailable = false;
if sc_ord > 0
  if c == iEUR
    a_PY_ord = 1;
  else
    a_PY_ord = avgFor_EUR(sc_ord, c);
  end
  b_PY_ord = avgEUR_SEK(sc_ord);
  if a_PY_ord ~= 0 && b_PY_ord ~= 0
    bomPYavailable = true;
  end
end

% --- Actual rate paths ---
if c == iEUR
  a_path = ones(M, 1);
else
  a_path = dm.fx{c, iEUR};
  if isempty(a_path), return; end
end
b_path = f_EUR_SEK;

% Validate window: all rates non-NaN over [t_ord, t_pay]
if any(isnan(a_path(t_ord:t_pay))) || any(isnan(b_path(t_ord:t_pay))), return; end

% --- Discount curve for this event (foreign currency c) ---
%   discCurve is the [nDates x nMaturities] discount factor matrix for currency
%   c, or [] if useDiscounting is false (no PV adjustment, face × FX only).
if useDiscounting
  if c == iEUR
    % EUR-denominated events: use EUR discount curve
    discCurve = dm.d{iEUR};
  else
    discCurve = dm.d{c};
  end
  if isempty(discCurve)
    discCurve = [];  % fall back to no-discount if curve missing for this currency
  end
else
  discCurve = [];
end

% --- (1) Snap mode: single contribution at t_rec ---
a_rec = a_path(t_rec);
b_rec = b_path(t_rec);
da    = a_rec - a_PY;
db    = b_rec - b_PY;
D_rec = discountFactorAt(discCurve, t_rec, t_pay);   % 1 if no discounting
trans_snap_m(s_rec)  = trans_snap_m(s_rec)  + signFlow * C * D_rec * da   * b_PY;
transl_snap_m(s_rec) = transl_snap_m(s_rec) + signFlow * C * D_rec * a_PY * db;
cross_snap_m(s_rec)  = cross_snap_m(s_rec)  + signFlow * C * D_rec * da   * db;

% --- (2) Bonds mode: lifecycle [t_rec, t_pay] ---
[d_tr, d_trsl, d_cr] = lifecycleDailyContribs(C, signFlow, t_rec, t_pay, a_path, b_path, a_PY, b_PY, discCurve);
buckets = d2s(t_rec:t_pay);
valid   = buckets > 0;
if any(valid)
  trans_bonds_m  = trans_bonds_m  + accumarray(buckets(valid), d_tr(valid),   [nSub, 1]);
  transl_bonds_m = transl_bonds_m + accumarray(buckets(valid), d_trsl(valid), [nSub, 1]);
  cross_bonds_m  = cross_bonds_m  + accumarray(buckets(valid), d_cr(valid),   [nSub, 1]);
end

% --- (3) BOM mode: lifecycle [t_ord, t_pay] anchored at t_ord's PY ---
% Daily PAM machinery starting at t_ord, but with (a_PY_ord, b_PY_ord)
% as the frozen anchor instead of (a_PY, b_PY). This makes BOM a
% substantively different measure than bonds: bonds asks "deviation from
% PY rates at recognition month" while BOM asks "deviation from PY rates
% at order month". The anchor difference is what breaks the algebraic
% identity that previously forced bonds and BOM cumulatives to match.
%
% Skipped if t_ord's PY data is unavailable (e.g., t_ord in year 1).
if bomPYavailable
  [d_tr_bom, d_trsl_bom, d_cr_bom] = lifecycleDailyContribs( ...
    C, signFlow, t_ord, t_pay, a_path, b_path, a_PY_ord, b_PY_ord, discCurve);
  buckets_bom = d2s(t_ord:t_pay);
  valid_bom   = buckets_bom > 0;
  if any(valid_bom)
    trans_BOM_m  = trans_BOM_m  + accumarray(buckets_bom(valid_bom), d_tr_bom(valid_bom),   [nSub, 1]);
    transl_BOM_m = transl_BOM_m + accumarray(buckets_bom(valid_bom), d_trsl_bom(valid_bom), [nSub, 1]);
    cross_BOM_m  = cross_BOM_m  + accumarray(buckets_bom(valid_bom), d_cr_bom(valid_bom),   [nSub, 1]);
  end
end

end


%% =========================================================================
function [d_trans, d_transl, d_cross] = lifecycleDailyContribs( ...
  C, signFlow, t_start, t_end, a_path, b_path, a_PY, b_PY, discCurve)
% Daily contributions over [t_start, t_end], one row per day.
% Day 1 (= t_start) gets the "initial" contribution F_*(t_start) - 0;
% subsequent days get F_*(t) - F_*(t-1).
%
% If discCurve is non-empty, each running F is multiplied by the discount
% factor d_{c,t}(T-t) so the contributions reflect the ZCB present value
% rather than face × FX. At t = t_end the discount factor is 1 (pull to par),
% so the cumulative value over the window is unchanged — only the time
% distribution within the window shifts toward later quarters.

t_window = (t_start:t_end)';
a = a_path(t_window);
b = b_path(t_window);

% Discount factor at each day (or 1 if no discounting)
if isempty(discCurve)
  D = ones(length(t_window), 1);
else
  D = zeros(length(t_window), 1);
  for i = 1:length(t_window)
    D(i) = discountFactorAt(discCurve, t_window(i), t_end);
  end
end

% Running CC values at end of each day (with discount applied)
F_trans  = C * D .* b_PY .* (a - a_PY);
F_transl = C * D .* a_PY .* (b - b_PY);
F_cross  = C * D .* (a - a_PY) .* (b - b_PY);

% Daily contributions: leading element = first-day initial (F(1) - 0)
d_trans  = signFlow * [F_trans(1);  diff(F_trans)];
d_transl = signFlow * [F_transl(1); diff(F_transl)];
d_cross  = signFlow * [F_cross(1);  diff(F_cross)];
end


%% =========================================================================
function D = discountFactorAt(discCurve, t_idx, t_pay)
% Discount factor at date t_idx for time-to-maturity (t_pay - t_idx + 1) days.
% Returns 1 if discCurve is empty (no PV adjustment).
if isempty(discCurve)
  D = 1;
  return;
end
ttm = max(1, t_pay - t_idx + 1);
ttm = min(ttm, size(discCurve, 2));
D = discCurve(t_idx, ttm);
if isnan(D) || D <= 0
  D = 1;   % fall back if curve has gaps
end
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
function [orderByInv, payByInv] = buildARLookups(dc)
% Build per-invoice-number lookup of (orderDate, payDate) for AR.
%   orderDate: via dc.sa  (sales-order table) and dc.productOrderDate
%   payDate:   via matching transactionCode == 20 row in dc.a

orderByInv = containers.Map('KeyType', 'double', 'ValueType', 'double');
payByInv   = containers.Map('KeyType', 'double', 'ValueType', 'double');

% Pay date: scan code-20 rows, key by invoice number
arRows20 = find(dc.a.transactionCode == 20);
for k = 1:length(arRows20)
  r = arRows20(k);
  payByInv(dc.a.invoiceNumber(r)) = dc.a.accountingDate(r);
end

% Order date: for each product, scan its sales-order rows in dc.sa, attach
% the product's productOrderDate to each invoice number found
if isfield(dc, 'sa') && isfield(dc, 'productNumbers') && isfield(dc, 'productOrderDate')
  for pi = 1:length(dc.productNumbers)
    pNum = dc.productNumbers(pi);
    saRows = find(dc.sa.itemNumber == pNum);
    for sm = 1:length(saRows)
      invNum = dc.sa.invoiceNumber(saRows(sm));
      orderByInv(invNum) = dc.productOrderDate(pi);
    end
  end
end
end


%% =========================================================================
function [orderByInv, payByInv] = buildAPLookups(dc)
% Build per-invoice-number lookup of (orderDate, payDate) for AP.
%   orderDate: via dc.p.purchaseOrderNumber == ap.invoiceNumber -> dc.p.orderDate
%   payDate:   via matching transactionCode == 20 row in dc.ap

orderByInv = containers.Map('KeyType', 'double', 'ValueType', 'double');
payByInv   = containers.Map('KeyType', 'double', 'ValueType', 'double');

% Pay date
apRows20 = find(dc.ap.transactionCode == 20);
for k = 1:length(apRows20)
  r = apRows20(k);
  payByInv(dc.ap.invoiceNumber(r)) = dc.ap.accountingDate(r);
end

% Order date: dc.p has one row per PO; join on PO number
if isfield(dc, 'p') && istable(dc.p) && ismember('purchaseOrderNumber', dc.p.Properties.VariableNames) ...
   && ismember('orderDate', dc.p.Properties.VariableNames)
  for k = 1:height(dc.p)
    orderByInv(dc.p.purchaseOrderNumber(k)) = dc.p.orderDate(k);
  end
end
end


%% =========================================================================
function ti = dateToIdx(dates, target)
% First date in 'dates' that is >= target. Empty if not found.
ti = find(dates >= target, 1, 'first');
end


%% =========================================================================
function ti = lookupDateIdx(map, key, dates)
% Look up date in containers.Map, then convert to dates(:) index.
ti = [];
if ~isKey(map, key), return; end
ti = find(dates >= map(key), 1, 'first');
end


%% =========================================================================
function [sStart, sEnd] = buildSubPeriodGrid(dates, window)
% Mirror of computeCC's local buildSubPeriodGrid for identical bucketing.
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
    error('performanceAttributionFlowCC:badWindow', ...
      'window must be ''week'', ''month'', or ''quarter''.');
end
changes = [1; find(diff(key) ~= 0) + 1];
sStart  = changes;
sEnd    = [changes(2:end) - 1; M];
end


%% =========================================================================
function compIdx = findComparisonPeriod(dates, sStart, d2s)
% Mirror of computeCC's findComparisonPeriod (12 calendar months back, day
% clamped to 28 to avoid Feb-29 issues).
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
