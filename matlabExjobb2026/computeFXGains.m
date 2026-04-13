function [fxg] = computeFXGains(dm, dc, periodDates)
% computeFXGains  Realized and unrealized FX gains on AR and AP per period.
%
%   fxg = computeFXGains(dm, dc)
%   fxg = computeFXGains(dm, dc, periodDates)
%
%   Implements thesis Eqs. 4.13-4.17 in functional currency (EUR).
%
%   periodDates : (P+1)x1 vector of period boundary dates.
%                 If omitted, quarterly boundaries are auto-generated from dm.
%
% Reference rate t^ref (per thesis):
%   = first recognition date (invoice/order date) if within the current period
%   = previous period-end closing date            if carried over from prior period
%
% Sign convention (consistent with thesis Eqs. 4.13-4.16, gain > 0 = P&L benefit):
%   AR : positive when transaction currency strengthens vs EUR (receive more EUR)
%   AP : positive when transaction currency weakens   vs EUR (pay less EUR)
%        => AP formula negated relative to the raw rate-change, see below.

% =========================================================================
% Period dates
% =========================================================================
if nargin < 3 || isempty(periodDates)
  periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
end

nPeriods    = length(periodDates) - 1;
firstDate   = dm.dates(1);
lastDate    = dm.dates(end);
indAllDates = dm.indAllDates;

iCurFunctional = find(ismember(dm.cName, 'EUR'));

% Helper: FX rate (transaction currency -> EUR) at a given calendar date.
% Clamps to dm date range; copies last known value for out-of-range dates.
  function e = getFX(iCur, calDate)
    d = min(max(calDate, firstDate), lastDate);
    e = dm.fx{iCur, iCurFunctional}(indAllDates(d - firstDate + 1));
  end

% =========================================================================
% Pre-allocate output
% =========================================================================
fxg.periodDates  = periodDates;
fxg.AR_real      = zeros(nPeriods, 1);   % Eq. 4.13
fxg.AR_unreal    = zeros(nPeriods, 1);   % Eq. 4.14
fxg.AP_real      = zeros(nPeriods, 1);   % Eq. 4.15
fxg.AP_unreal    = zeros(nPeriods, 1);   % Eq. 4.16

% =========================================================================
% Collect AR invoice pairs once (avoid repeated find() in inner loop)
% =========================================================================
ar_codes = dc.a.transactionCode;
ar_inv   = dc.a.invoiceNumber;
ar_date  = dc.a.accountingDate;
ar_amt   = dc.a.foreignCurrencyAmount;
ar_iCur  = dc.a.iCur;

arNums = unique(ar_inv(ar_codes == 10));
nAR    = length(arNums);
arData = struct('t_del', zeros(nAR,1), 't_set', zeros(nAR,1), ...
                'A',     zeros(nAR,1), 'iCur',  zeros(nAR,1));

for i = 1:nAR
  jj = find(ar_codes == 10 & ar_inv == arNums(i));
  kk = find(ar_codes == 20 & ar_inv == arNums(i));
  if isempty(jj) || isempty(kk), continue; end
  arData.t_del(i) = ar_date(jj);
  arData.t_set(i) = ar_date(kk);
  arData.A(i)     = ar_amt(jj);
  arData.iCur(i)  = ar_iCur(jj);
end

% =========================================================================
% Collect AP order pairs once
% =========================================================================
ap_codes = dc.ap.transactionCode;
ap_inv   = dc.ap.invoiceNumber;
ap_date  = dc.ap.accountingDate;
ap_amt   = dc.ap.foreignCurrencyAmount;
ap_iCur  = dc.ap.iCur;

apNums = unique(ap_inv(ap_codes == 10));
nAP    = length(apNums);
apData = struct('t_proc', zeros(nAP,1), 't_pay', zeros(nAP,1), ...
                'C',      zeros(nAP,1), 'iCur',  zeros(nAP,1));

for i = 1:nAP
  jj = find(ap_codes == 10 & ap_inv == apNums(i));
  kk = find(ap_codes == 20 & ap_inv == apNums(i));
  if isempty(jj) || isempty(kk), continue; end
  apData.t_proc(i) = ap_date(jj);
  apData.t_pay(i)  = ap_date(kk);
  apData.C(i)      = ap_amt(jj);    % positive amount owed
  apData.iCur(i)   = ap_iCur(jj);
end

% =========================================================================
% Main period loop
% =========================================================================
for p = 1:nPeriods
  T_prev = periodDates(p);      % start of period (= end of previous)
  T_p    = periodDates(p + 1);  % end of period

  % Skip periods entirely outside dm range
  if T_p <= firstDate || T_prev >= lastDate, continue; end

  % ------ AR (Eqs. 4.13-4.14) ------------------------------------------
  for i = 1:nAR
    t_del = arData.t_del(i);
    t_set = arData.t_set(i);
    A_j   = arData.A(i);
    iCur  = arData.iCur(i);
    if A_j == 0 || iCur == 0, continue; end

    % Reference rate
    if t_del > T_prev && t_del <= T_p
      t_ref = t_del;   % first recognition in this period
    else
      t_ref = T_prev;  % carried over: use previous period-end closing rate
    end

    % Realized (Eq. 4.13): settled within this period, after being recognised
    if t_set > T_prev && t_set <= T_p && t_del <= T_p
      e_set = getFX(iCur, t_set);
      e_ref = getFX(iCur, t_ref);
      fxg.AR_real(p) = fxg.AR_real(p) + A_j * (e_set - e_ref);
    end

    % Unrealized (Eq. 4.14): recognised but not yet settled at period end
    if t_del <= T_p && t_set > T_p
      e_Tp  = getFX(iCur, T_p);
      e_ref = getFX(iCur, t_ref);
      fxg.AR_unreal(p) = fxg.AR_unreal(p) + A_j * (e_Tp - e_ref);
    end
  end

  % ------ AP (Eqs. 4.15-4.16) ------------------------------------------
  % Sign: AP gain is positive when the company pays LESS EUR than at reference.
  % If foreign currency weakens (e_pay < e_ref), payment in EUR decreases -> gain.
  % => AP gain = -C * (e_pay - e_ref)  =  C * (e_ref - e_pay)
  for i = 1:nAP
    t_proc = apData.t_proc(i);
    t_pay  = apData.t_pay(i);
    C_jl   = apData.C(i);
    iCur   = apData.iCur(i);
    if C_jl == 0 || iCur == 0, continue; end

    % Reference rate
    if t_proc > T_prev && t_proc <= T_p
      t_ref = t_proc;
    else
      t_ref = T_prev;
    end

    % Realized (Eq. 4.15)
    if t_pay > T_prev && t_pay <= T_p && t_proc <= T_p
      e_pay = getFX(iCur, t_pay);
      e_ref = getFX(iCur, t_ref);
      fxg.AP_real(p) = fxg.AP_real(p) - C_jl * (e_pay - e_ref);
    end

    % Unrealized (Eq. 4.16)
    if t_proc <= T_p && t_pay > T_p
      e_Tp  = getFX(iCur, T_p);
      e_ref = getFX(iCur, t_ref);
      fxg.AP_unreal(p) = fxg.AP_unreal(p) - C_jl * (e_Tp - e_ref);
    end
  end

end % period loop

% =========================================================================
% Totals
% =========================================================================
fxg.AR_total  = fxg.AR_real   + fxg.AR_unreal;
fxg.AP_total  = fxg.AP_real   + fxg.AP_unreal;
fxg.total     = fxg.AR_total  + fxg.AP_total;   % Eq. 4.17

end % computeFXGains
