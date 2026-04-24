function m2 = computeMethod2(dm, dc, verboseQuarter)
% computeMethod2  Compute Method 2 (sub-period avg rate) FX impacts for
% all three averaging windows (weekly, monthly, quarterly).
%
%   m2 = computeMethod2(dm, dc)
%   m2 = computeMethod2(dm, dc, 'YYYY-Qn')   % debug print one quarter
%
% Orchestrates:
%   1. Balance sheet  (buildBalanceSheet.m)
%   2. Functional-currency P&L  (buildFunctionalPnL.m)
%   3. Three Method 2 variants  (translateMethod2.m)
%   4. Quarterly TI and OCI per eq 4.21 and 4.22-4.25 of the thesis
%
% Outputs:
%   m2.weekly          - struct with .TI, .OCI, debug fields (sub-period = calendar week)
%   m2.monthly         - same for sub-period = calendar month
%   m2.quarterly       - same for sub-period = calendar quarter
%   m2.periodEndDates  [Q x 1]
%   m2.periodStartDates[Q x 1]
%   m2.bs              - shared balance sheet
%   m2.pnl             - shared EUR P&L

if nargin < 3, verboseQuarter = ''; end

% Add shared-core folder and Method1 (for fmtNum) to path
thisDir   = fileparts(mfilename('fullpath'));
parentDir = fileparts(thisDir);
addpath(parentDir);

bs  = buildBalanceSheet(dm, dc);
pnl = buildFunctionalPnL(dm, dc, bs);

m2.weekly    = translateMethod2(dm, pnl, bs, 'week');
m2.monthly   = translateMethod2(dm, pnl, bs, 'month');
m2.quarterly = translateMethod2(dm, pnl, bs, 'quarter');

m2.periodEndDates   = dm.dates(pnl.quarterEndIdx);
m2.periodStartDates = dm.dates(pnl.quarterStartIdx);
m2.bs  = bs;
m2.pnl = pnl;

if ~isempty(verboseQuarter)
  printMethod2Debug(verboseQuarter, dm, pnl, bs, m2);
end

end


function printMethod2Debug(qLabel, dm, pnl, bs, m2)
% Verbose breakdown of one quarter under all three Method 2 variants

tok = regexp(qLabel, '^(\d{4})-Q(\d)$', 'tokens', 'once');
if isempty(tok)
  warning('verboseQuarter must be "YYYY-Qn" (e.g. 2015-Q2). Skipping.');
  return;
end
yy = str2double(tok{1});
qn = str2double(tok{2});

qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;

[Ys, Ms, ~] = datevec(dm.dates(qStart));
qOfStart = floor((Ms - 1) / 3) + 1;
matchIdx = find(Ys == yy & qOfStart == qn, 1);
if isempty(matchIdx)
  warning('Quarter %s not found in data range.', qLabel);
  return;
end
q = matchIdx;
tS = qStart(q);
tE = qEnd(q);

iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));
f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};

fprintf('\n========================================================================\n');
fprintf('  METHOD 2 DEBUG  —  %s  (%s to %s)\n', qLabel, ...
        datestr(dm.dates(tS),'yyyy-mm-dd'), datestr(dm.dates(tE),'yyyy-mm-dd'));
fprintf('========================================================================\n');

% Shared EUR P&L for the quarter
fprintf('\n-- Shared EUR P&L for quarter (same under all M2 variants) -----------\n');
fprintf('  I_R (Revenue)  : %18s\n', fmtNum(pnl.I_R(tE),  2));
fprintf('  I_C (COGS)     : %18s\n', fmtNum(pnl.I_C(tE),  2));
fprintf('  I_F (Total FX) : %18s\n', fmtNum(pnl.I_F(tE),  2));
fprintf('  I_N (Net inc.) : %18s\n', fmtNum(pnl.I_N(tE),  2));

% Show sub-period count and avg rate range for each variant
fprintf('\n-- Sub-periods inside this quarter -----------------------------------\n');
fprintf('%-10s %8s %10s %10s %10s\n', 'Variant', 'Count', 'min avg f', 'max avg f', 'mean avg f');
variants = {'weekly', 'monthly', 'quarterly'};
for v = 1:3
  mv = m2.(variants{v});
  rng = tS:tE;
  subQ = mv.subId(rng);
  avgQ = mv.dayAvgRate(rng);
  [u, iu] = unique(subQ);
  rates  = avgQ(iu);
  fprintf('%-10s %8d %10.4f %10.4f %10.4f\n', ...
    variants{v}, length(u), min(rates), max(rates), mean(rates));
end

% Per-variant TI and OCI
fprintf('\n-- Quarter results per variant ---------------------------------------\n');
fprintf('%-10s %18s %18s\n', 'Variant', 'TI (SEK)', 'OCI (SEK)');
fprintf('%s\n', repmat('-', 1, 50));
for v = 1:3
  mv = m2.(variants{v});
  fprintf('%-10s %18s %18s\n', variants{v}, fmtNum(mv.TI(q), 2), fmtNum(mv.OCI(q), 2));
end

% Balance-sheet references
BN_close_SEK = bs.B_N(tE) * f_EUR_SEK(tE);
if q == 1
  BN_open_SEK = 0;
else
  tPrev = qEnd(q - 1);
  BN_open_SEK = bs.B_N(tPrev) * f_EUR_SEK(tPrev);
end
divInQuarter_SEK = sum(bs.dividendEUR(tS:tE) .* f_EUR_SEK(tS:tE));

fprintf('\n-- Balance-sheet references (same for all variants) -----------------\n');
fprintf('  B_N_open (SEK)     : %18s\n', fmtNum(BN_open_SEK, 2));
fprintf('  B_N_close (SEK)    : %18s\n', fmtNum(BN_close_SEK, 2));
fprintf('  Dividend in Q (SEK): %18s\n', fmtNum(divInQuarter_SEK, 2));
fprintf('========================================================================\n\n');

end
