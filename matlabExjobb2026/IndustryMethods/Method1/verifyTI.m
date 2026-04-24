function verifyTI(dm, dc, qLabel)
% verifyTI  Decompose Method 1 Transactional Impact for one quarter into
% per-transaction contributions. Prints a table and totals for manual checking.
%
%   verifyTI(dm, dc, 'YYYY-Qn')
%
% For each AR and AP outstanding at any point during the quarter, prints:
%   - Invoice number, currency, face value
%   - Delivery and payment dates
%   - Days outstanding during the quarter
%   - FX contribution in EUR to unrealized/realized during the quarter
%   - Same contribution translated to SEK at daily rates
%
% The sum of SEK contributions should match the quarterly TI from
% computeMethod1 exactly.

% --- Parse quarter ---
tok = regexp(qLabel, '^(\d{4})-Q(\d)$', 'tokens', 'once');
if isempty(tok), error('verifyTI: use format "YYYY-Qn"'); end
yy = str2double(tok{1});  qn = str2double(tok{2});
qStartMonth = 3*(qn-1) + 1;
tS = datenum(yy, qStartMonth, 1);
tE = datenum(yy, qStartMonth + 3, 0);   % last day of quarter

% --- Currency indices ---
iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));

% --- Find quarter bounds in dm.dates ---
idxStart = find(dm.dates >= tS, 1, 'first');
idxEnd   = find(dm.dates <= tE, 1, 'last');
idxPrev  = idxStart - 1;   % day before quarter start (for "opening rate")
if idxPrev < 1, idxPrev = 1; end

f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};

fprintf('\n========================================================================\n');
fprintf('  TI VERIFICATION  —  %s  (%s to %s)\n', qLabel, ...
        datestr(dm.dates(idxStart),'yyyy-mm-dd'), datestr(dm.dates(idxEnd),'yyyy-mm-dd'));
fprintf('========================================================================\n\n');

grandTotalSEK = 0;

%% -------------------- AR --------------------
fprintf('--- AR contributions ---\n');
fprintf('%-6s %-4s %14s %-10s %-10s %14s %14s\n', ...
  'Inv', 'Cur', 'Face', 'Deliv', 'Pay', 'dFX EUR', 'dFX SEK');

invRows = find(dc.a.transactionCode == 10);
for k = 1:length(invRows)
  r1 = invRows(k);
  c  = dc.a.iCur(r1);
  if c == iCurFunctional, continue; end   % no FX on EUR
  tD = dc.a.accountingDate(r1);
  % Find payment
  r2 = find(dc.a.transactionCode == 20 & dc.a.invoiceNumber == dc.a.invoiceNumber(r1), 1);
  if isempty(r2), tP = dm.dates(end) + 1;
  else,          tP = dc.a.accountingDate(r2);
  end
  % Skip if AR never overlaps the quarter
  if tP <= tS || tD > tE, continue; end

  face   = dc.a.foreignCurrencyAmount(r1);
  curStr = dc.a.currency{r1};
  fx_c   = dm.fx{c, iCurFunctional};

  % Revaluation days IN Q that include this AR:
  %  - If delivered BEFORE Q started: reval on first day of Q already counts
  %      (face was already on books at end of prev Q)
  %  - If delivered IN Q: reval happens day AFTER delivery (face = 0 on day of delivery)
  if tD < tS
    tFirst = idxStart;
  else
    iDeliv = find(dm.dates >= tD, 1, 'first');
    tFirst = iDeliv + 1;
  end
  %  - If paid IN Q: payment day itself has a reval (face still on books yesterday),
  %      then reclass (FU → FR) which is FX-neutral for total I_F
  %  - If still open at Q end: last day of Q has final reval
  if tP <= tE
    tLast = find(dm.dates >= tP, 1, 'first');
    if isempty(tLast), tLast = idxEnd; end
  else
    tLast = idxEnd;
  end

  % Daily FX change per day: diff(fx_c)(k) = fx_c(k+1) - fx_c(k)
  dFX_EUR_daily = face * diff(fx_c);
  dFX_SEK_daily = dFX_EUR_daily .* f_EUR_SEK(2:end);

  % For a reval happening on day t, use diff index (t-1)
  if tFirst <= tLast && tFirst > 1
    diffRange = (tFirst - 1) : (tLast - 1);
    dFX_EUR = sum(dFX_EUR_daily(diffRange));
    dFX_SEK = sum(dFX_SEK_daily(diffRange));
  else
    dFX_EUR = 0; dFX_SEK = 0;
  end

  if abs(dFX_SEK) > 0.01
    fprintf('%-6d %-4s %14.2f %-10s %-10s %14.2f %14.2f\n', ...
      dc.a.invoiceNumber(r1), curStr, face, ...
      datestr(tD,'yyyy-mm-dd'), ...
      iif(~isempty(r2), datestr(tP,'yyyy-mm-dd'), 'open'), ...
      dFX_EUR, dFX_SEK);
    grandTotalSEK = grandTotalSEK + dFX_SEK;
  end
end

%% -------------------- AP --------------------
fprintf('\n--- AP contributions (AP contributes with opposite sign) ---\n');
fprintf('%-6s %-4s %14s %-10s %-10s %14s %14s\n', ...
  'PO', 'Cur', 'Face', 'Deliv', 'Pay', 'dFX EUR', 'dFX SEK');

apRows = find(dc.ap.transactionCode == 10);
for k = 1:length(apRows)
  r1 = apRows(k);
  c  = dc.ap.iCur(r1);
  if c == iCurFunctional, continue; end
  tD = dc.ap.accountingDate(r1);
  r2 = find(dc.ap.transactionCode == 20 & dc.ap.invoiceNumber == dc.ap.invoiceNumber(r1), 1);
  if isempty(r2), tP = dm.dates(end) + 1;
  else,          tP = dc.ap.accountingDate(r2);
  end
  if tP <= tS || tD > tE, continue; end

  face   = dc.ap.foreignCurrencyAmount(r1);
  curStr = dc.ap.currency{r1};
  fx_c   = dm.fx{c, iCurFunctional};

  if tD < tS
    tFirst = idxStart;
  else
    iDeliv = find(dm.dates >= tD, 1, 'first');
    tFirst = iDeliv + 1;
  end
  if tP <= tE
    tLast = find(dm.dates >= tP, 1, 'first');
    if isempty(tLast), tLast = idxEnd; end
  else
    tLast = idxEnd;
  end

  dFX_EUR_daily = -face * diff(fx_c);       % AP: negative sign
  dFX_SEK_daily = dFX_EUR_daily .* f_EUR_SEK(2:end);

  if tFirst <= tLast && tFirst > 1
    diffRange = (tFirst - 1) : (tLast - 1);
    dFX_EUR = sum(dFX_EUR_daily(diffRange));
    dFX_SEK = sum(dFX_SEK_daily(diffRange));
  else
    dFX_EUR = 0; dFX_SEK = 0;
  end

  if abs(dFX_SEK) > 0.01
    fprintf('%-6d %-4s %14.2f %-10s %-10s %14.2f %14.2f\n', ...
      dc.ap.invoiceNumber(r1), curStr, face, ...
      datestr(tD,'yyyy-mm-dd'), ...
      iif(~isempty(r2), datestr(tP,'yyyy-mm-dd'), 'open'), ...
      dFX_EUR, dFX_SEK);
    grandTotalSEK = grandTotalSEK + dFX_SEK;
  end
end

fprintf('\n--------------------------------------------------------------------\n');
fprintf('  Sum of per-transaction TI contributions (SEK) : %18.2f\n', grandTotalSEK);
fprintf('  (Compare to TI reported by computeMethod1 for this quarter.)\n');
fprintf('========================================================================\n\n');

end

function out = iif(cond, a, b)
  if cond, out = a; else, out = b; end
end
