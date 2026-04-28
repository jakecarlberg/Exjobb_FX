function cc = computeCC(dm, dc, pnl, bs, window, verboseMonth)
% computeCC  Constant-currency (CC) FX impact — three variants.
%
%   cc = computeCC(dm, dc, pnl, bs, window)
%
% window:        'week' | 'month' | 'quarter'  (thesis specifies 'month')
% verboseMonth:  optional, e.g. '2022-03' — prints step-by-step verification for that month
%
% CC has two additive sub-components:
%   CC^trans  — effect of FX rate movements on the period's cash flows
%   CC^transl — effect of EUR/SEK movements on the translation of net income
%
% CC^transl is method-independent (same EUR P&L regardless of M1/M2):
%   CC^transl = I^N_s × (f̄_s,EUR→SEK − f̄_sc,EUR→SEK)
%
% CC^trans differs by method/variant:
%
%   M1 variant (actual daily rate for current period):
%     CC^trans = [Σ C^S_i × f_{t^D_i,c→SEK} − Σ C^P_p × f_{t^D_p,c→SEK}]
%              − [Σ C^S_i − Σ C^P_p] × avgRate_sc   (prior-yr monthly avg)
%
%   avg variant (monthly average rate, same for M2):
%     CC^trans = Σ_c [salesFlow(s,c) − procFlow(s,c)] × (avgRate_s_c − avgRate_sc_c)
%
%   close variant (period-opening closing rate):
%     CC^trans = Σ_c [salesFlow(s,c) − procFlow(s,c)] × (openRate_s_c − openRate_sc_c)
%
% c→SEK rates are triangular: dm.fx{c,EUR} × dm.fx{EUR,SEK}.
%
% Outputs:
%   cc.M1.raw_TI / raw_OCI          [nSub x 1]  (NaN where no comparison period)
%   cc.M1.quarterly_TI / quarterly_OCI  [Q x 1]
%   cc.avg.*   — same structure
%   cc.close.* — same structure
%   cc.subEndDates    [nSub x 1]
%   cc.periodEndDates [Q x 1]
%   cc.window         string

if nargin < 6, verboseMonth = ''; end

M    = length(dm.dates);
nCur = length(dm.cName);
iEUR = find(strcmp(dm.cName, 'EUR'));
iSEK = find(strcmp(dm.cName, 'SEK'));

f_EUR_SEK = dm.fx{iEUR, iSEK};   % EUR → SEK daily rate

%% =========================================================================
%  1. Sub-period grid
%% =========================================================================
[sStart, sEnd] = buildSubPeriodGrid(dm.dates, window);
nSub = length(sStart);

% Fast date → sub-period lookup
d2s = zeros(M, 1);
for s = 1:nSub
  d2s(sStart(s):sEnd(s)) = s;
end

%% =========================================================================
%  2. c→SEK average and opening rates per sub-period
%     Rate: f_{c→SEK} = f_{c→EUR} × f_{EUR→SEK}
%% =========================================================================
avgRate  = zeros(nSub, nCur);   % mean c→SEK over sub-period
openRate = zeros(nSub, nCur);   % c→SEK on last day before sub-period starts

for c = 1:nCur
  if c == iSEK
    avgRate(:, c) = 1;  openRate(:, c) = 1;
    continue;
  end
  if c == iEUR
    fx = f_EUR_SEK;
  else
    fxCEUR = dm.fx{c, iEUR};
    if isempty(fxCEUR), continue; end
    fx = fxCEUR .* f_EUR_SEK;
  end
  for s = 1:nSub
    v    = fx(sStart(s):sEnd(s));
    good = ~isnan(v);
    if any(good), avgRate(s, c) = mean(v(good)); end
    if sStart(s) > 1
      op = fx(sStart(s) - 1);
      if ~isnan(op), openRate(s, c) = op;
      else,          openRate(s, c) = avgRate(s, c); end
    else
      openRate(s, c) = avgRate(s, c);
    end
  end
end

%% =========================================================================
%  3. Comparison-period index for each sub-period (12 calendar months back)
%% =========================================================================
compIdx = findComparisonPeriod(dm.dates, sStart, d2s);

%% =========================================================================
%  4. Net currency flows per sub-period
%     salesFlow(s, c)  = Σ C^S_i  (transaction currency c, sub-period s)
%     procFlow(s, c)   = Σ C^P_p
%     m1_salesSEK(s)   = Σ C^S_i × f_{t^D_i, c→SEK}   (actual day rate, M1)
%     m1_procSEK(s)    = Σ C^P_p × f_{t^D_p, c→SEK}
%% =========================================================================
salesFlow   = zeros(nSub, nCur);
procFlow    = zeros(nSub, nCur);
m1_salesSEK = zeros(nSub, 1);
m1_procSEK  = zeros(nSub, 1);

dateIdxFn = @(d) find(dm.dates >= d, 1, 'first');

invRowsAR = find(dc.a.transactionCode == 10);
for k = 1:length(invRowsAR)
  r  = invRowsAR(k);
  ti = dateIdxFn(dc.a.accountingDate(r));
  if isempty(ti), continue; end
  s  = d2s(ti);
  if s == 0, continue; end
  c  = dc.a.iCur(r);
  C  = dc.a.foreignCurrencyAmount(r);
  salesFlow(s, c) = salesFlow(s, c) + C;
  fxAct = actualCSEK(dm, c, iSEK, iEUR, f_EUR_SEK, ti);
  if ~isnan(fxAct), m1_salesSEK(s) = m1_salesSEK(s) + C * fxAct; end
end

apRows = find(dc.ap.transactionCode == 10);
for k = 1:length(apRows)
  r  = apRows(k);
  ti = dateIdxFn(dc.ap.accountingDate(r));
  if isempty(ti), continue; end
  s  = d2s(ti);
  if s == 0, continue; end
  c  = dc.ap.iCur(r);
  C  = dc.ap.foreignCurrencyAmount(r);
  procFlow(s, c) = procFlow(s, c) + C;
  fxAct = actualCSEK(dm, c, iSEK, iEUR, f_EUR_SEK, ti);
  if ~isnan(fxAct), m1_procSEK(s) = m1_procSEK(s) + C * fxAct; end
end

%% =========================================================================
%  5. CC per sub-period
%% =========================================================================
raw_TI_M1    = nan(nSub, 1);   raw_OCI_M1    = nan(nSub, 1);
raw_TI_avg   = nan(nSub, 1);   raw_OCI_avg   = nan(nSub, 1);
raw_TI_close = nan(nSub, 1);   raw_OCI_close = nan(nSub, 1);

for s = 1:nSub
  sc = compIdx(s);
  if sc == 0, continue; end

  sf = salesFlow(s, :);
  pf = procFlow(s, :);

  rd_avg   = zeroNaN(avgRate(s,:)  - avgRate(sc,:));
  rd_close = zeroNaN(openRate(s,:) - openRate(sc,:));

  % Shared translation component (same for all variants)
  I_N_s  = sum(pnl.dI_N(sStart(s):sEnd(s)));
  OCI_sh = I_N_s * (avgRate(s, iEUR) - avgRate(sc, iEUR));

  % M1: actual delivery-date rate for current period, prior-yr monthly avg for comparison
  avRcomp = zeroNaN(avgRate(sc, :));
  raw_TI_M1(s)  = (m1_salesSEK(s) - m1_procSEK(s)) ...
                - (sum(sf .* avRcomp) - sum(pf .* avRcomp));
  raw_OCI_M1(s) = OCI_sh;

  % avg variant: monthly avg rate for both periods
  raw_TI_avg(s)  = sum(sf .* rd_avg) - sum(pf .* rd_avg);
  raw_OCI_avg(s) = OCI_sh;

  % close variant: period-opening closing rate; transl = avg (thesis eq. cc_transl_close)
  raw_TI_close(s)  = sum(sf .* rd_close) - sum(pf .* rd_close);
  raw_OCI_close(s) = OCI_sh;
end

if ~isempty(verboseMonth)
  printCCDebug(verboseMonth, dm, dc, pnl, sStart, sEnd, compIdx, ...
    salesFlow, procFlow, m1_salesSEK, m1_procSEK, avgRate, openRate, ...
    raw_TI_M1, raw_OCI_M1, raw_TI_avg, raw_OCI_avg, raw_TI_close, raw_OCI_close, ...
    iEUR, iSEK);
end

%% =========================================================================
%  6. Aggregate to reporting quarters
%% =========================================================================
qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;
Q      = length(qStart);

[TI_M1_q,    OCI_M1_q]    = aggToQtrs(raw_TI_M1,    raw_OCI_M1,    sEnd, qStart, qEnd, Q);
[TI_avg_q,   OCI_avg_q]   = aggToQtrs(raw_TI_avg,   raw_OCI_avg,   sEnd, qStart, qEnd, Q);
[TI_close_q, OCI_close_q] = aggToQtrs(raw_TI_close, raw_OCI_close, sEnd, qStart, qEnd, Q);

%% =========================================================================
%  7. Output
%% =========================================================================
cc.M1.raw_TI         = raw_TI_M1;      cc.M1.raw_OCI         = raw_OCI_M1;
cc.M1.quarterly_TI   = TI_M1_q;        cc.M1.quarterly_OCI   = OCI_M1_q;

cc.avg.raw_TI        = raw_TI_avg;     cc.avg.raw_OCI        = raw_OCI_avg;
cc.avg.quarterly_TI  = TI_avg_q;       cc.avg.quarterly_OCI  = OCI_avg_q;

cc.close.raw_TI      = raw_TI_close;   cc.close.raw_OCI      = raw_OCI_close;
cc.close.quarterly_TI = TI_close_q;    cc.close.quarterly_OCI = OCI_close_q;

cc.subEndDates    = dm.dates(sEnd);
cc.periodEndDates = dm.dates(qEnd);
cc.window         = window;

end


%% =========================================================================
function [sStart, sEnd] = buildSubPeriodGrid(dates, window)
M = length(dates);
[Y, Mo, ~] = datevec(dates);
Y = Y(:);  Mo = Mo(:);
switch lower(window)
  case 'month'
    key = Y * 100 + Mo;
  case 'quarter'
    key = Y * 10 + floor((Mo - 1) / 3) + 1;
  case 'week'
    refMon = datenum(1970, 1, 5);
    key    = floor((dates(:) - refMon) / 7);
  otherwise
    error('computeCC:badWindow', 'window must be ''week'', ''month'', or ''quarter''.');
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


%% =========================================================================
function [TI_q, OCI_q] = aggToQtrs(rawTI, rawOCI, sEnd, qStart, qEnd, Q)
TI_q  = zeros(Q, 1);
OCI_q = zeros(Q, 1);
for q = 1:Q
  mask = (sEnd >= qStart(q)) & (sEnd <= qEnd(q));
  v = rawTI(mask);  TI_q(q)  = sum(v(~isnan(v)));
  v = rawOCI(mask); OCI_q(q) = sum(v(~isnan(v)));
end
end


%% =========================================================================
function v = zeroNaN(v)
v(isnan(v)) = 0;
end


%% =========================================================================
function printCCDebug(monthStr, dm, dc, pnl, sStart, sEnd, compIdx, ...
  salesFlow, procFlow, m1_salesSEK, m1_procSEK, avgRate, openRate, ...
  raw_TI_M1, raw_OCI_M1, raw_TI_avg, raw_OCI_avg, raw_TI_close, raw_OCI_close, ...
  iEUR, iSEK)

tok = regexp(monthStr, '^(\d{4})-(\d{2})$', 'tokens', 'once');
if isempty(tok)
  warning('verboseMonth must be ''YYYY-MM'' (e.g. ''2022-03''). Skipping.');
  return;
end
targetYr = str2double(tok{1});
targetMo = str2double(tok{2});

[Ys, Ms, ~] = datevec(dm.dates(sStart));
s = find(Ys == targetYr & Ms == targetMo, 1);
if isempty(s)
  warning('Month %s not found in sub-period grid. Skipping.', monthStr);
  return;
end
sc = compIdx(s);
f_EUR_SEK = dm.fx{iEUR, iSEK};

fprintf('\n');
fprintf('================================================================================\n');
fprintf('  CC DEBUG  —  %s  (%s  to  %s)\n', monthStr, ...
  datestr(dm.dates(sStart(s)), 'yyyy-mm-dd'), ...
  datestr(dm.dates(sEnd(s)),   'yyyy-mm-dd'));
if sc == 0
  fprintf('  No comparison period found (first year). Cannot compute CC.\n');
  fprintf('================================================================================\n\n');
  return;
end
[Ysc, Msc] = datevec(dm.dates(sStart(sc)));
fprintf('  Comparison : %04d-%02d  (%s  to  %s)\n', Ysc, Msc, ...
  datestr(dm.dates(sStart(sc)), 'yyyy-mm-dd'), ...
  datestr(dm.dates(sEnd(sc)),   'yyyy-mm-dd'));
fprintf('================================================================================\n');

nCur = length(dm.cName);
tS   = sStart(s);
tE   = sEnd(s);
dateRange = [dm.dates(tS), dm.dates(tE)];

% Helper: actual c→SEK rate at date index ti
actRate = @(c, ti) getActRate(dm, c, iSEK, iEUR, f_EUR_SEK, ti);
dateIdx = @(d) find(dm.dates >= d, 1, 'first');

% --- Individual transactions --------------------------------------------
fprintf('\n-- Individual transactions in %s -----------------------------------------------\n', monthStr);
w = 120;
hdr = '%-5s %-12s %-6s %16s %10s %10s %10s %16s %16s';
fprintf([hdr '\n'], 'Type', 'Date', 'Curr', 'Amount(FC)', 'f_actual', 'f_avg_CY', 'f_avg_LY', 'M1_contrib', 'avg_contrib');
fprintf('%s\n', repmat('-', 1, w));

check_m1_sales = 0;  check_avg_sales = 0;
check_m1_proc  = 0;  check_avg_proc  = 0;

% Sales
invRows = find(dc.a.transactionCode == 10);
for k = 1:length(invRows)
  r = invRows(k);
  d = dc.a.accountingDate(r);
  if d < dateRange(1) || d > dateRange(2), continue; end
  ti  = dateIdx(d);
  c   = dc.a.iCur(r);
  if c == iSEK, continue; end
  amt = dc.a.foreignCurrencyAmount(r);
  fAct = actRate(c, ti);
  fCY  = avgRate(s,  c);
  fLY  = avgRate(sc, c);
  if isnan(fLY), fLY = 0; end
  m1c  =  amt * (fAct - fLY);
  avgc =  amt * (fCY  - fLY);
  check_m1_sales  = check_m1_sales  + amt * fAct;
  check_avg_sales = check_avg_sales + amt * fCY;
  fprintf([hdr '\n'], 'Sale', datestr(d,'yyyy-mm-dd'), dm.cName{c}, ...
    fmtN(amt), fAct, fCY, fLY, fmtN(m1c), fmtN(avgc));
end

% Procurement
apRows = find(dc.ap.transactionCode == 10);
for k = 1:length(apRows)
  r = apRows(k);
  d = dc.ap.accountingDate(r);
  if d < dateRange(1) || d > dateRange(2), continue; end
  ti  = dateIdx(d);
  c   = dc.ap.iCur(r);
  if c == iSEK, continue; end
  amt = dc.ap.foreignCurrencyAmount(r);
  fAct = actRate(c, ti);
  fCY  = avgRate(s,  c);
  fLY  = avgRate(sc, c);
  if isnan(fLY), fLY = 0; end
  m1c  = -amt * (fAct - fLY);
  avgc = -amt * (fCY  - fLY);
  check_m1_proc  = check_m1_proc  + amt * fAct;
  check_avg_proc = check_avg_proc + amt * fCY;
  fprintf([hdr '\n'], 'Proc', datestr(d,'yyyy-mm-dd'), dm.cName{c}, ...
    fmtN(amt), fAct, fCY, fLY, fmtN(m1c), fmtN(avgc));
end

% LY avg denominator for M1
avRcomp_all = avgRate(sc, :);
avRcomp_all(isnan(avRcomp_all)) = 0;
m1_LY_sales = sum(salesFlow(s,:) .* avRcomp_all);
m1_LY_proc  = sum(procFlow(s,:)  .* avRcomp_all);

fprintf('%s\n', repmat('-', 1, w));
m1_total  = (check_m1_sales  - check_m1_proc)  - (m1_LY_sales - m1_LY_proc);
avg_total = (check_avg_sales - check_avg_proc) - (m1_LY_sales - m1_LY_proc);
fprintf('  Σ sales×f_actual=%s   Σ proc×f_actual=%s\n', fmtN(check_m1_sales), fmtN(check_m1_proc));
fprintf('  Σ sales×f_avg_LY=%s  Σ proc×f_avg_LY=%s\n', fmtN(m1_LY_sales), fmtN(m1_LY_proc));
fprintf('  CC^trans(M1)  = (%s − %s) − (%s − %s) = %s\n', ...
  fmtN(check_m1_sales), fmtN(check_m1_proc), fmtN(m1_LY_sales), fmtN(m1_LY_proc), fmtN(m1_total));
fprintf('  CC^trans(avg) = (%s − %s) − (%s − %s) = %s\n', ...
  fmtN(check_avg_sales), fmtN(check_avg_proc), fmtN(m1_LY_sales), fmtN(m1_LY_proc), fmtN(avg_total));
fprintf('  Stored M1=%s   avg=%s\n', fmtN(raw_TI_M1(s)), fmtN(raw_TI_avg(s)));

% --- Aggregated rate table (sanity check) --------------------------------
fprintf('\n-- Aggregated flows per currency (sanity check vs. stored salesFlow/procFlow) ---\n');
fprintf('%-6s %10s %10s %10s %10s %16s %16s\n', ...
  'Curr', 'AvgRate_CY', 'AvgRate_LY', 'OpenRate_CY', 'OpenRate_LY', 'CC^trans(avg)', 'CC^trans(close)');
fprintf('%s\n', repmat('-', 1, 100));
tot_avg2 = 0; tot_close2 = 0;
for c = 1:nCur
  if c == iSEK, continue; end
  sf = salesFlow(s,c); pf = procFlow(s,c);
  if sf == 0 && pf == 0, continue; end
  net   = sf - pf;
  rCY   = avgRate(s,c);   rLY  = avgRate(sc,c);  if isnan(rLY),  rLY  = 0; end
  oCY   = openRate(s,c);  oLY  = openRate(sc,c); if isnan(oLY),  oLY  = 0; end
  caAvg = net*(rCY-rLY);  caCls = net*(oCY-oLY);
  tot_avg2   = tot_avg2   + caAvg;
  tot_close2 = tot_close2 + caCls;
  fprintf('%-6s %10.4f %10.4f %10.4f %10.4f %16s %16s\n', ...
    dm.cName{c}, rCY, rLY, oCY, oLY, fmtN(caAvg), fmtN(caCls));
end
fprintf('%s\n', repmat('-', 1, 100));
fprintf('%-6s %10s %10s %10s %10s %16s %16s\n', 'TOTAL','','','','',fmtN(tot_avg2),fmtN(tot_close2));
fprintf('  Stored: avg=%s   close=%s\n', fmtN(raw_TI_avg(s)), fmtN(raw_TI_close(s)));

% --- CC^transl (shared) -------------------------------------------------
I_N_s   = sum(pnl.dI_N(sStart(s):sEnd(s)));
rEUR_CY = avgRate(s,  iEUR);
rEUR_LY = avgRate(sc, iEUR);
OCI_sh  = I_N_s * (rEUR_CY - rEUR_LY);
fprintf('\n-- CC^transl (shared across all variants) --------------------------------------\n');
fprintf('  I_N_EUR (net income this month, EUR) : %s\n', fmtN(I_N_s));
fprintf('  avgRate EUR/SEK  CY                  : %.6f\n', rEUR_CY);
fprintf('  avgRate EUR/SEK  LY                  : %.6f\n', rEUR_LY);
fprintf('  delta-rate                           : %.6f\n', rEUR_CY - rEUR_LY);
fprintf('  CC^transl = I_N_EUR x delta-rate     : %s\n', fmtN(OCI_sh));
fprintf('  Stored raw_OCI                       : %s\n', fmtN(raw_OCI_M1(s)));

% --- Summary ------------------------------------------------------------
fprintf('\n-- Summary for %s -----------------------------------------------------------\n', monthStr);
fprintf('%-22s %18s %18s %18s\n', 'Variant', 'CC^trans', 'CC^transl', 'CC total');
fprintf('%s\n', repmat('-', 1, 80));
fprintf('%-22s %18s %18s %18s\n', 'M1 (daily vs LY avg)', ...
  fmtN(raw_TI_M1(s)), fmtN(raw_OCI_M1(s)), fmtN(raw_TI_M1(s)+raw_OCI_M1(s)));
fprintf('%-22s %18s %18s %18s\n', 'avg-rate', ...
  fmtN(raw_TI_avg(s)), fmtN(raw_OCI_avg(s)), fmtN(raw_TI_avg(s)+raw_OCI_avg(s)));
fprintf('%-22s %18s %18s %18s\n', 'closing-rate', ...
  fmtN(raw_TI_close(s)), fmtN(raw_OCI_close(s)), fmtN(raw_TI_close(s)+raw_OCI_close(s)));
fprintf('%s\n', repmat('-', 1, 80));
fprintf('================================================================================\n\n');
end


%% =========================================================================
function s = fmtN(x)
if isnan(x), s = 'NaN'; return; end
neg = x < 0;
intStr = sprintf('%.0f', floor(abs(x)));
n = length(intStr);
pos = n - 3;
while pos > 0
  intStr = [intStr(1:pos) ',' intStr(pos+1:end)];
  pos = pos - 3;
end
if neg, s = ['-' intStr]; else, s = intStr; end
end


%% =========================================================================
function fx = getActRate(dm, c, iSEK, iEUR, f_EUR_SEK, ti)
if c == iSEK
  fx = 1;
elseif c == iEUR
  fx = f_EUR_SEK(ti);
else
  fxCEUR = dm.fx{c, iEUR};
  if isempty(fxCEUR), fx = NaN; return; end
  fx = fxCEUR(ti) * f_EUR_SEK(ti);
end
end


%% =========================================================================
function fx = actualCSEK(dm, c, iSEK, iEUR, f_EUR_SEK, t)
if c == iSEK,   fx = 1; return; end
if c == iEUR,   fx = f_EUR_SEK(t); return; end
fxCEUR = dm.fx{c, iEUR};
if isempty(fxCEUR), fx = NaN; return; end
fx = fxCEUR(t) * f_EUR_SEK(t);
end
