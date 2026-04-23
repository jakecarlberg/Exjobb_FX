function m1 = computeMethod1(dm, dc, verboseQuarter)
% computeMethod1  Compute Method 1 (actual-rate) FX impacts for the full period.
%
%   m1 = computeMethod1(dm, dc)
%   m1 = computeMethod1(dm, dc, 'YYYY-Qn')   % print detailed breakdown of one quarter
%
% Example:
%   m1 = computeMethod1(dm, dc, '2015-Q2')   % prints inputs/outputs for Q2 2015
%
% Orchestrates:
%   1. Balance sheet construction     (buildBalanceSheet.m)
%   2. Functional-currency P&L        (buildFunctionalPnL.m)
%   3. Method 1 translation to SEK    (translateMethod1.m)
%   4. Quarterly TI and OCI per eq 4.21 and 4.22-4.25 of the thesis
%
% Outputs (per quarter):
%   m1.periodEndDates  [Q x 1]  - last trading day of each quarter
%   m1.TI              [Q x 1]  - Transactional Impact in SEK  (eq 4.21)
%   m1.OCI             [Q x 1]  - Translation Impact (OCI) in SEK  (eq 4.22-4.25)
%
% Also stored for debugging/inspection:
%   m1.bs       - daily balance sheet (from buildBalanceSheet)
%   m1.pnl      - daily P&L in EUR     (from buildFunctionalPnL)
%   m1.m1raw    - daily P&L in SEK     (from translateMethod1)

if nargin < 3, verboseQuarter = ''; end

% Add parent folder to path so buildBalanceSheet.m and buildFunctionalPnL.m
% are found regardless of current working directory.
thisDir = fileparts(mfilename('fullpath'));
parentDir = fileparts(thisDir);
addpath(parentDir);

bs    = buildBalanceSheet(dm, dc);
pnl   = buildFunctionalPnL(dm, dc, bs);
m1raw = translateMethod1(dm, pnl, bs);

iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));
f_EUR_SEK        = dm.fx{iCurFunctional, iCurPresentation};

qStart = pnl.quarterStartIdx;
qEnd   = pnl.quarterEndIdx;
Q      = length(qEnd);

% --- Transactional Impact (eq 4.21): FX gain/loss in SEK at quarter end
TI = m1raw.I_F_SEK(qEnd);

% --- Translation Impact / OCI (eq 4.22-4.25)
% B^N_t = B^I_t + B^W_t + AR_EUR - AP_EUR + B^C_t  (from buildBalanceSheet)
%
% For each quarter p ending at T_p with preceding quarter end T_{p-1}:
%   B^{N,P}_{T_p}  = B^N_{T_p}   * f_{T_p, EUR, SEK}        (closing NA @ closing rate)
%   B^{E,P}_{m,p} = B^N_{T_{p-1}} * f_{T_{p-1}, EUR, SEK}
%                 + I^{N,P}_{M1, T_p}                      (expected NA)
%   B^O_{m,p}    = B^{N,P}_{T_p} - B^{E,P}_{m,p}           (OCI)
%
% For the FIRST quarter, the opening balance is zero (our simulation starts
% with B^I_0 = B^C_0 = 0 and no AR/AP outstanding), so we use index 0 → B^N=0.

OCI = zeros(Q, 1);
for q = 1:Q
  tStart = qStart(q);
  tEnd   = qEnd(q);
  if q == 1
    BN_open_SEK = 0;                                 % opening balance is zero
  else
    tPrevEnd     = qEnd(q - 1);
    BN_open_SEK  = bs.B_N(tPrevEnd) * f_EUR_SEK(tPrevEnd);
  end
  BN_close_SEK = bs.B_N(tEnd) * f_EUR_SEK(tEnd);
  I_N_SEK_q    = m1raw.I_N_SEK(tEnd);                % quarterly net income in SEK (Method 1)

  % Dividends paid to parent during this quarter, translated at sweep-day rate.
  % These reduce B_N but don't flow through P&L, so we subtract them from the
  % expected net assets (otherwise OCI picks up the dividend as a phantom loss).
  divInQuarter = sum(bs.dividendEUR(tStart:tEnd) .* f_EUR_SEK(tStart:tEnd));

  BE_SEK = BN_open_SEK + I_N_SEK_q - divInQuarter;
  OCI(q) = BN_close_SEK - BE_SEK;
end

m1.periodEndDates = dm.dates(qEnd);
m1.periodStartDates = dm.dates(qStart);
m1.TI   = TI;
m1.OCI  = OCI;

% Store intermediate structures for debugging
m1.bs    = bs;
m1.pnl   = pnl;
m1.m1raw = m1raw;

% --- Verbose debug print for one quarter -------------------------------
if ~isempty(verboseQuarter)
  printQuarterDebug(verboseQuarter, dm, dc, bs, pnl, m1raw, f_EUR_SEK, qStart, qEnd);
end

end


function printQuarterDebug(qLabel, dm, dc, bs, pnl, m1raw, f_EUR_SEK, qStart, qEnd)
% Parse 'YYYY-Qn' and print a detailed Method 1 breakdown for that quarter.
% Uses the same formulas as the main loop above so the output exactly matches
% OCI/TI computed for that quarter.

tok = regexp(qLabel, '^(\d{4})-Q(\d)$', 'tokens', 'once');
if isempty(tok)
  warning('verboseQuarter must be "YYYY-Qn" (e.g. 2015-Q2). Skipping.');
  return;
end
yy = str2double(tok{1});
qn = str2double(tok{2});

% Find the matching quarter index
[Ys, Ms, ~] = datevec(dm.dates(qStart));
qOfStart = floor((Ms - 1) / 3) + 1;
matchIdx = find(Ys == yy & qOfStart == qn, 1);
if isempty(matchIdx)
  warning('Quarter %s not found in data range. Skipping.', qLabel);
  return;
end
q = matchIdx;

tS = qStart(q);
tE = qEnd(q);

fprintf('\n========================================================================\n');
fprintf('  METHOD 1 DEBUG  —  %s  (%s to %s)\n', qLabel, ...
        datestr(dm.dates(tS), 'yyyy-mm-dd'), datestr(dm.dates(tE), 'yyyy-mm-dd'));
fprintf('========================================================================\n');

fprintf('\n-- Balance Sheet (EUR) at quarter end ---------------------------------\n');
fprintf('  B_I  (Inventory)         : %18s\n', fmtNum(bs.B_I(tE), 2));
fprintf('  B_W  (WIP)               : %18s\n', fmtNum(bs.B_W(tE), 2));
fprintf('  AR_EUR                   : %18s\n', fmtNum(bs.AR_EUR(tE), 2));
fprintf('  AP_EUR                   : %18s\n', fmtNum(bs.AP_EUR(tE), 2));
fprintf('  B_C  (Cash)              : %18s\n', fmtNum(bs.B_C(tE), 2));
fprintf('  B_N  (Net Assets)        : %18s\n', fmtNum(bs.B_N(tE), 2));

if q == 1
  fprintf('\n-- Opening (start of data): B_N = 0 ----------------------------------\n');
  tPrevEnd    = 0;
  BN_open_EUR = 0;
  BN_open_SEK = 0;
  f_open      = NaN;
else
  tPrevEnd    = qEnd(q - 1);
  BN_open_EUR = bs.B_N(tPrevEnd);
  f_open      = f_EUR_SEK(tPrevEnd);
  BN_open_SEK = BN_open_EUR * f_open;
  fprintf('\n-- Opening (end of previous quarter, %s) -----------------------\n', ...
          datestr(dm.dates(tPrevEnd), 'yyyy-mm-dd'));
  fprintf('  B_N_open (EUR)           : %18s\n', fmtNum(BN_open_EUR, 2));
  fprintf('  f_open (EUR/SEK)         : %18.6f\n', f_open);
  fprintf('  B_N_open (SEK)           : %18s\n', fmtNum(BN_open_SEK, 2));
end

f_close      = f_EUR_SEK(tE);
BN_close_EUR = bs.B_N(tE);
BN_close_SEK = BN_close_EUR * f_close;

fprintf('\n-- Closing (end of quarter, %s) --------------------------------\n', ...
        datestr(dm.dates(tE), 'yyyy-mm-dd'));
fprintf('  B_N_close (EUR)          : %18s\n', fmtNum(BN_close_EUR, 2));
fprintf('  f_close (EUR/SEK)        : %18.6f\n', f_close);
fprintf('  B_N_close (SEK)          : %18s\n', fmtNum(BN_close_SEK, 2));

fprintf('\n-- P&L during quarter (EUR, quarterly reset) -------------------------\n');
fprintf('  I_R  (Revenue)           : %18s\n', fmtNum(pnl.I_R(tE), 2));
fprintf('  I_C  (COGS)              : %18s\n', fmtNum(pnl.I_C(tE), 2));
fprintf('  I_FU (Unreal FX)         : %18s\n', fmtNum(pnl.I_FU(tE), 2));
fprintf('  I_FR (Real FX)           : %18s\n', fmtNum(pnl.I_FR(tE), 2));
fprintf('  I_F  (Total FX)          : %18s\n', fmtNum(pnl.I_F(tE), 2));
fprintf('  I_N  (Net Income)        : %18s\n', fmtNum(pnl.I_N(tE), 2));

fprintf('\n-- P&L during quarter (SEK, Method 1, daily translation) -------------\n');
fprintf('  I_R_SEK                  : %18s\n', fmtNum(m1raw.I_R_SEK(tE), 2));
fprintf('  I_C_SEK                  : %18s\n', fmtNum(m1raw.I_C_SEK(tE), 2));
fprintf('  I_F_SEK                  : %18s\n', fmtNum(m1raw.I_F_SEK(tE), 2));
fprintf('  I_N_SEK                  : %18s\n', fmtNum(m1raw.I_N_SEK(tE), 2));

% Dividends in this quarter
divInQuarter_SEK = sum(bs.dividendEUR(tS:tE) .* f_EUR_SEK(tS:tE));
divInQuarter_EUR = sum(bs.dividendEUR(tS:tE));
if divInQuarter_EUR > 0
  fprintf('\n-- Dividends to parent during quarter --------------------------------\n');
  fprintf('  Dividend (EUR)           : %18s\n', fmtNum(divInQuarter_EUR, 2));
  fprintf('  Dividend (SEK @ day rate): %18s\n', fmtNum(divInQuarter_SEK, 2));
end

fprintf('\n-- Final impacts ------------------------------------------------------\n');
TI_q  = m1raw.I_F_SEK(tE);
BE_SEK = BN_open_SEK + m1raw.I_N_SEK(tE) - divInQuarter_SEK;
OCI_q = BN_close_SEK - BE_SEK;
fprintf('  TI   = I_F_SEK(T_p)                                    = %18s\n', fmtNum(TI_q, 2));
fprintf('  B_E  = B_N_open_SEK + I_N_SEK - Div_SEK\n');
fprintf('       = %s + %s - %s = %s\n', ...
        fmtNum(BN_open_SEK, 2), fmtNum(m1raw.I_N_SEK(tE), 2), ...
        fmtNum(divInQuarter_SEK, 2), fmtNum(BE_SEK, 2));
fprintf('  OCI  = B_N_close_SEK - B_E\n');
fprintf('       = %s - %s = %s\n', ...
        fmtNum(BN_close_SEK, 2), fmtNum(BE_SEK, 2), fmtNum(OCI_q, 2));
fprintf('========================================================================\n\n');

end
