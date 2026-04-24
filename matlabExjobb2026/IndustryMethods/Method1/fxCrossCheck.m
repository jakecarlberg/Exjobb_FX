function fxCrossCheck(dm, m1)
% fxCrossCheck  Compare Method 1 TI and OCI per quarter against actual
% FX movements. Useful sanity check: weak SEK should give positive OCI
% (EUR net assets worth more when translated), and broad foreign-currency
% strengthening should give positive TI (AR grows faster than AP on average).
%
%   fxCrossCheck(dm, m1)

iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));
iUSD = find(ismember(dm.cName, 'USD'));

f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};
f_USD_EUR = dm.fx{iUSD, iCurFunctional};

nQ = length(m1.periodEndDates);

fprintf('\n========================================================================\n');
fprintf('  FX CROSS-CHECK  —  per-quarter rate movements vs Method 1 impacts\n');
fprintf('========================================================================\n\n');
fprintf('%-12s %10s %10s %10s %10s %10s %16s %16s\n', ...
  'Period end', 'EUR/SEK', 'dEUR/SEK', 'USD/EUR', 'dUSD/EUR', 'dEUR/SEK%', 'TI (SEK)', 'OCI (SEK)');
fprintf('%s\n', repmat('-', 1, 116));

for q = 1:nQ
  tEnd = m1.periodEndDates(q);
  idxEnd = find(dm.dates == tEnd, 1);
  if isempty(idxEnd), continue; end

  if q == 1
    idxStart = 1;
  else
    prevEnd  = m1.periodEndDates(q - 1);
    idxStart = find(dm.dates == prevEnd, 1);
  end

  f_ES_end   = f_EUR_SEK(idxEnd);
  f_ES_start = f_EUR_SEK(idxStart);
  d_ES       = f_ES_end - f_ES_start;
  d_ES_pct   = 100 * d_ES / f_ES_start;

  f_UE_end   = f_USD_EUR(idxEnd);
  f_UE_start = f_USD_EUR(idxStart);
  d_UE       = f_UE_end - f_UE_start;

  fprintf('%-12s %10.4f %+10.4f %10.4f %+10.4f %+9.2f%% %16s %16s\n', ...
    datestr(tEnd, 'yyyy-mm-dd'), ...
    f_ES_end, d_ES, f_UE_end, d_UE, d_ES_pct, ...
    fmtNum(m1.TI(q), 0), fmtNum(m1.OCI(q), 0));
end

fprintf('\nInterpretation hints:\n');
fprintf('  dEUR/SEK > 0 : EUR strengthened vs SEK during quarter (SEK weakened)\n');
fprintf('                 → positive OCI expected (EUR net assets translate to more SEK)\n');
fprintf('  dUSD/EUR > 0 : USD strengthened vs EUR during quarter\n');
fprintf('                 → positive TI expected if AR-USD > AP-USD (typical for our sim)\n');
fprintf('\n');

end
