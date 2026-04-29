% runExcelExport  Full single-run pipeline with comprehensive Excel export.
%
% Sheets exported:
%   1.  Annual              — Annual FX results (TI, OCI, CC variants)
%   2.  Quarterly           — Quarterly FX results
%   3.  Daily_PortfolioValue— V_EUR, V_SEK, all constant-currency runs
%   4.  Daily_FXImpact      — Daily FX attribution (trans/transl/CC)
%   5.  Daily_PAMTerms      — All 13 PAM P&L decomposition terms (EUR)
%   6.  Daily_FXRates       — All spot FX rates to EUR and SEK
%   7.  Daily_CashHoldings  — Cash by currency (local + EUR equivalent)
%   8.  Daily_Instruments   — Instrument holdings by currency (EUR equiv)
%   9.  Daily_Transactions  — Buy/sell volumes by currency (EUR equiv)
%   10. PortfolioSummary    — V_EUR decomposition check
%   11. PurchaseOrders      — Raw purchase order records
%   12. StockTransactions   — Raw stock transaction records
%   13. AccountsReceivable  — Raw AR records
%   14. AccountsPayable     — Raw AP records
%   15. Sales               — Raw sales invoice records
%   16. BOM                 — Bill of materials records
%
% Output: PAM_full_export.xlsx  (saved to Exjobb_FX root folder)

if ~exist('dr', 'var')
  cd(fileparts(mfilename('fullpath')));

  % =======================================================================
  % SETTINGS
  % =======================================================================
  settings.dataFolder         = 'simulatedData';
  settings.bomPricing         = 'DeterministicCashFlows';
  settings.curFunctional      = 'EUR';
  settings.startDate          = datenum(2007,1,1);
  settings.endDate            = datenum(2024,12,31);
  settings.usedItemNumbersOrg = [];
  settings.usedProductNumbers = [];
  settings.currencies         = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

  % =======================================================================
  % PIPELINE
  % =======================================================================
  fprintf('Loading market data (2007-2024)...\n'); tic;
  dm = createDataMarket('reutersZero', settings);
  fprintf('Done (%.1fs). %d dates, %d currencies\n\n', toc, length(dm.dates), length(dm.cName));

  fprintf('Simulating transactions...\n'); tic;
  createMatFilesSim(dm, 1, false);
  dc = createDataCompany(dm, settings);
  dp = buildPA(dm, dc);
  fprintf('Done (%.1fs)\n\n', toc);

  fprintf('Running performanceAttribution...\n'); tic;
  dr = performanceAttribution(dm, dc, dp, false);
  fprintf('Done (%.1fs)\n\n', toc);

  addpath(fullfile('IndustryMethods'));
  addpath(fullfile('IndustryMethods','Method1'));
  addpath(fullfile('IndustryMethods','Method2'));

  fprintf('Running Method 1 & 2...\n'); tic;
  bs = buildBalanceSheet(dm, dc);
  pnl = buildFunctionalPnL(dm, dc, bs);
  m1 = computeMethod1(dm, dc, '', bs, pnl);
  m2 = computeMethod2(dm, dc, '', bs, pnl);
  fprintf('Done (%.1fs)\n\n', toc);

  % ---- Sensitivity: no-discount PAM (standalone mode) --------------------
  runSensitivityNoDiscount = true;   % set to false to skip (~30% faster)
  if runSensitivityNoDiscount
    fprintf('Running no-discount PAM sensitivity...\n'); tic;
    d_backup_xls = dm.d;
    for c_nd_xls = 1:length(dm.cName)
      dm.d{c_nd_xls} = ones(size(dm.d{c_nd_xls}));
    end
    dp_nd = buildPA(dm, dc);
    dr_nd = performanceAttribution(dm, dc, dp_nd, false);
    dm.d  = d_backup_xls;
    fprintf('Done (%.1fs)\n\n', toc);
  end
else
  fprintf('Reusing workspace variables from runPA.\n\n');
end

% =========================================================================
% DERIVED QUANTITIES
% =========================================================================
M   = length(dm.dates);
Nc  = length(dm.cName);
N   = size(dp.Pbar, 2);
iEUR = find(ismember(dm.cName, 'EUR'));
iSEK = find(ismember(dm.cName, 'SEK'));

dateStrs = cellstr(datestr(dm.dates, 'yyyy-mm-dd'));

% Cumulative holdings
hI = [dp.hI0; repmat(dp.hI0,M-1,1) + ...
      cumsum(full(dp.xBI(2:end,:)) - full(dp.xSI(2:end,:)))];

% Cash in EUR equivalent
cashEUR = zeros(M, Nc);
for k = 1:Nc
  cashEUR(:,k) = dr.hC(:,k) .* dm.fx{k,iEUR};
end

% Instrument holdings by currency (EUR equiv) — all instruments
hIPbar_byCcy = zeros(M, Nc);
for k = 1:Nc
  ind = find(dc.assets.pricingCurrency() == k);
  if ~isempty(ind)
    hIPbar_byCcy(:,k) = sum(hI(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
  end
end

% Components value in EUR (itemInventory + itemShrinkage, at procurement cost)
compIdx = [dc.assets.indPriceInventory, dc.assets.indPriceShrinkage];
compEUR = zeros(M, 1);
for k = 1:Nc
  ind = intersect(compIdx, find(dc.assets.pricingCurrency() == k));
  if ~isempty(ind)
    compEUR = compEUR + sum(hI(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
  end
end

% WIP value in EUR (itemManufactured, at ex-ante selling revenue)
wipIdx = dc.assets.indManufactured;
wipEUR = zeros(M, 1);
for k = 1:Nc
  ind = intersect(wipIdx, find(dc.assets.pricingCurrency() == k));
  if ~isempty(ind)
    wipEUR = wipEUR + sum(hI(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
  end
end

% Bond (AR/AP zero-coupon) value in EUR — total and per currency
bondIdx       = dc.assets.indBond;
bondsEUR      = zeros(M, 1);
bondsByCcyEUR = zeros(M, Nc);
for k = 1:Nc
  ind = intersect(bondIdx, find(dc.assets.pricingCurrency() == k));
  if ~isempty(ind)
    v = sum(hI(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
    bondsByCcyEUR(:,k) = v;
    bondsEUR = bondsEUR + v;
  end
end

% Buy/sell volumes by currency (EUR equiv)
xBI_full = full(dp.xBI);
xSI_full = full(dp.xSI);
buyByCcy  = zeros(M, Nc);
sellByCcy = zeros(M, Nc);
for k = 1:Nc
  ind = find(dc.assets.pricingCurrency() == k);
  if ~isempty(ind)
    buyByCcy(:,k)  = sum(xBI_full(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
    sellByCcy(:,k) = sum(xSI_full(:,ind) .* dp.Pbar(:,ind), 2) .* dm.fx{k,iEUR};
  end
end

% FX rates
ratesEUR = zeros(M, Nc);
ratesSEK = zeros(M, Nc);
for k = 1:Nc
  ratesEUR(:,k) = dm.fx{k,iEUR};
  ratesSEK(:,k) = dm.fx{k,iSEK};
end

% =========================================================================
% QUARTERLY & ANNUAL AGGREGATION
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;
qLabels     = cellstr(datestr(periodDates(2:end), 'yyyy-Qq'));
[qYears,~,~]= datevec(periodDates(2:end));
uniqueYears = unique(qYears);
nYears      = length(uniqueYears);

TI_q=zeros(nPeriods,1); TI_BOM_q=zeros(nPeriods,1); OCI_q=zeros(nPeriods,1);
CCt_q=zeros(nPeriods,1); CCtr_q=zeros(nPeriods,1); CCtl_q=zeros(nPeriods,1);
CCt_LY_q=zeros(nPeriods,1); CCtr_LY_q=zeros(nPeriods,1); CCtl_LY_q=zeros(nPeriods,1);

for p = 1:nPeriods
  idx = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
  if ~isempty(idx)
    TI_q(p)      = sum(dr.dFX_trans(idx));
    TI_BOM_q(p)  = sum(dr.dFX_trans_BOM(idx));
    OCI_q(p)     = sum(dr.dFX_transl(idx));
    CCt_q(p)     = sum(dr.dFX_cc(idx));
    CCtr_q(p)    = sum(dr.dFX_trans_CC(idx));
    CCtl_q(p)    = sum(dr.dFX_transl_CC(idx));
    CCt_LY_q(p)  = sum(dr.dFX_cc_LY_total(idx));
    CCtr_LY_q(p) = sum(dr.dFX_trans_CC_LY(idx));
    CCtl_LY_q(p) = sum(dr.dFX_transl_CC_LY(idx));
  end
end

% Align Method 2 quarters to PAM quarter grid
m2TI_w_q=zeros(nPeriods,1); m2OCI_w_q=zeros(nPeriods,1);
m2TI_m_q=zeros(nPeriods,1); m2OCI_m_q=zeros(nPeriods,1);
m2TI_qt_q=zeros(nPeriods,1); m2OCI_qt_q=zeros(nPeriods,1);
for p = 1:nPeriods
  [~,mp] = min(abs(m2.periodEndDates - periodDates(p+1)));
  if abs(m2.periodEndDates(mp) - periodDates(p+1)) <= 5
    m2TI_w_q(p)=m2.weekly.TI(mp);    m2OCI_w_q(p)=m2.weekly.OCI(mp);
    m2TI_m_q(p)=m2.monthly.TI(mp);   m2OCI_m_q(p)=m2.monthly.OCI(mp);
    m2TI_qt_q(p)=m2.quarterly.TI(mp);m2OCI_qt_q(p)=m2.quarterly.OCI(mp);
  end
end

% Align Method 1 quarters to PAM quarter grid
m1TI_q  = zeros(nPeriods, 1);
m1OCI_q = zeros(nPeriods, 1);
for p = 1:nPeriods
  [~, mp] = min(abs(m1.periodEndDates - periodDates(p+1)));
  if abs(m1.periodEndDates(mp) - periodDates(p+1)) <= 5
    m1TI_q(p)  = m1.TI(mp);
    m1OCI_q(p) = m1.OCI(mp);
  end
end

TI_a=zeros(nYears,1); TI_BOM_a=zeros(nYears,1); OCI_a=zeros(nYears,1);
CCt_a=zeros(nYears,1); CCtr_a=zeros(nYears,1); CCtl_a=zeros(nYears,1);
CCt_LY_a=zeros(nYears,1); CCtr_LY_a=zeros(nYears,1); CCtl_LY_a=zeros(nYears,1);
m1TI_a=zeros(nYears,1); m1OCI_a=zeros(nYears,1);
m2TI_w_a=zeros(nYears,1); m2OCI_w_a=zeros(nYears,1);
m2TI_m_a=zeros(nYears,1); m2OCI_m_a=zeros(nYears,1);
m2TI_qt_a=zeros(nYears,1);m2OCI_qt_a=zeros(nYears,1);

for y = 1:nYears
  qM = (qYears == uniqueYears(y));
  TI_a(y)      = sum(TI_q(qM));    TI_BOM_a(y)  = sum(TI_BOM_q(qM));
  OCI_a(y)     = sum(OCI_q(qM));
  CCt_a(y)     = sum(CCt_q(qM));   CCtr_a(y)    = sum(CCtr_q(qM));  CCtl_a(y)    = sum(CCtl_q(qM));
  CCt_LY_a(y)  = sum(CCt_LY_q(qM));CCtr_LY_a(y) = sum(CCtr_LY_q(qM)); CCtl_LY_a(y) = sum(CCtl_LY_q(qM));
  m1TI_a(y)   = sum(m1TI_q(qM));   m1OCI_a(y)  = sum(m1OCI_q(qM));
  m2TI_w_a(y)=sum(m2TI_w_q(qM));   m2OCI_w_a(y)=sum(m2OCI_w_q(qM));
  m2TI_m_a(y)=sum(m2TI_m_q(qM));   m2OCI_m_a(y)=sum(m2OCI_m_q(qM));
  m2TI_qt_a(y)=sum(m2TI_qt_q(qM)); m2OCI_qt_a(y)=sum(m2OCI_qt_q(qM));
end

% ---- No-discount sensitivity aggregation --------------------------------
% haveSens is true when the sensitivity run was completed (either from
% runPA.m or from the standalone block above).
haveSens = exist('runSensitivityNoDiscount', 'var') && runSensitivityNoDiscount ...
           && exist('dr_nd', 'var');

TI_nd_q     = zeros(nPeriods, 1);
TI_BOM_nd_q = zeros(nPeriods, 1);
TI_nd_a     = zeros(nYears,   1);
TI_BOM_nd_a = zeros(nYears,   1);

if haveSens
  for p = 1:nPeriods
    idx = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p + 1));
    if ~isempty(idx)
      TI_nd_q(p)     = sum(dr_nd.dFX_trans(idx));
      TI_BOM_nd_q(p) = sum(dr_nd.dFX_trans_BOM(idx));
    end
  end
  for y = 1:nYears
    qM = (qYears == uniqueYears(y));
    TI_nd_a(y)     = sum(TI_nd_q(qM));
    TI_BOM_nd_a(y) = sum(TI_BOM_nd_q(qM));
  end
end

% Console print
fprintf('=== Annual Results (SEK) ===\n');
fprintf('%-6s %13s %13s %13s %13s %13s %13s\n','Year','TI (bonds)','TI (bonds+BOM)','OCI','CC_total','CC_trans','CC_transl');
fprintf('%s\n',repmat('-',1,90));
for y = 1:nYears
  fprintf('%-6d %13.0f %13.0f %13.0f %13.0f %13.0f %13.0f\n', ...
    uniqueYears(y),TI_a(y),TI_BOM_a(y),OCI_a(y),CCt_a(y),CCtr_a(y),CCtl_a(y));
end
fprintf('%s\n',repmat('-',1,90));
fprintf('%-6s %13.0f %13.0f %13.0f %13.0f %13.0f %13.0f\n','TOTAL', ...
  sum(TI_a),sum(TI_BOM_a),sum(OCI_a),sum(CCt_a),sum(CCtr_a),sum(CCtl_a));

% =========================================================================
% EXCEL EXPORT
% =========================================================================
xlFile = fullfile(fileparts(mfilename('fullpath')), '..', 'PAM_full_export.xlsx');
fprintf('\nWriting %s ...\n', xlFile);

% Helper: convert datenum column to date strings
dn2s = @(v) cellstr(datestr(v, 'yyyy-mm-dd'));

% -------------------------------------------------------------------------
% Sheet 1: Annual
% -------------------------------------------------------------------------
hdrA = {'Year', ...
  'PAM_TI_Bonds [SEK] (Eq.4.45)', 'PAM_TI_BondsBOM [SEK]', ...
  'Method1_TI [SEK]', 'Method2_Monthly_TI [SEK]', ...
  'Cumul_PAM_Bonds [SEK]', 'Cumul_PAM_BondsBOM [SEK]', ...
  'Cumul_Method1 [SEK]', 'Cumul_Method2_Monthly [SEK]', ...
  'Diff_M1_vs_PAM_Bonds [SEK]', 'Diff_M2m_vs_PAM_Bonds [SEK]', ...
  'Diff_M1_vs_PAM_BOM [SEK]',   'Diff_M2m_vs_PAM_BOM [SEK]'};
aData = [num2cell(uniqueYears), num2cell([...
  TI_a, TI_BOM_a, m1TI_a, m2TI_m_a, ...
  cumsum(TI_a), cumsum(TI_BOM_a), cumsum(m1TI_a), cumsum(m2TI_m_a), ...
  m1TI_a - TI_a,     m2TI_m_a - TI_a, ...
  m1TI_a - TI_BOM_a, m2TI_m_a - TI_BOM_a])];
totRow = [{'TOTAL'}, num2cell([...
  sum(TI_a), sum(TI_BOM_a), sum(m1TI_a), sum(m2TI_m_a), ...
  sum(TI_a), sum(TI_BOM_a), sum(m1TI_a), sum(m2TI_m_a), ...
  sum(m1TI_a)-sum(TI_a),     sum(m2TI_m_a)-sum(TI_a), ...
  sum(m1TI_a)-sum(TI_BOM_a), sum(m2TI_m_a)-sum(TI_BOM_a)])];
writecell([hdrA; aData; totRow], xlFile, 'Sheet', 'Annual');
fprintf('  Sheet  1/18: Annual\n');

% -------------------------------------------------------------------------
% Sheet 2: Quarterly
% -------------------------------------------------------------------------
hdrQ = {'Quarter', ...
  'PAM_TI_Bonds [SEK] (Eq.4.45)', 'PAM_TI_BondsBOM [SEK]', ...
  'PAM_OCI [SEK] (Eq.4.46)', 'PAM_CC_total [SEK] (Eq.4.47)', ...
  'PAM_CC_trans [SEK]', 'PAM_CC_transl [SEK]', ...
  'PAM_CC_total_LY [SEK]', 'PAM_CC_trans_LY [SEK]', 'PAM_CC_transl_LY [SEK]', ...
  'M2_Weekly_TI [SEK]', 'M2_Weekly_OCI [SEK]', ...
  'M2_Monthly_TI [SEK]', 'M2_Monthly_OCI [SEK]', ...
  'M2_Quarterly_TI [SEK]', 'M2_Quarterly_OCI [SEK]', ...
  'Diff_TI_Bonds_PAMvM2weekly [SEK]', 'Diff_TI_BOM_PAMvM2weekly [SEK]', 'Diff_OCI_PAMvM2weekly [SEK]', ...
  'Diff_TI_Bonds_PAMvM2monthly [SEK]', 'Diff_TI_BOM_PAMvM2monthly [SEK]', 'Diff_OCI_PAMvM2monthly [SEK]', ...
  'Diff_TI_Bonds_PAMvM2quarterly [SEK]', 'Diff_TI_BOM_PAMvM2quarterly [SEK]', 'Diff_OCI_PAMvM2quarterly [SEK]'};
qData = [qLabels, num2cell([...
  TI_q, TI_BOM_q, OCI_q, CCt_q, CCtr_q, CCtl_q, CCt_LY_q, CCtr_LY_q, CCtl_LY_q, ...
  m2TI_w_q, m2OCI_w_q, m2TI_m_q, m2OCI_m_q, m2TI_qt_q, m2OCI_qt_q, ...
  TI_q-m2TI_w_q,  TI_BOM_q-m2TI_w_q,  OCI_q-m2OCI_w_q, ...
  TI_q-m2TI_m_q,  TI_BOM_q-m2TI_m_q,  OCI_q-m2OCI_m_q, ...
  TI_q-m2TI_qt_q, TI_BOM_q-m2TI_qt_q, OCI_q-m2OCI_qt_q])];
writecell([hdrQ; qData], xlFile, 'Sheet', 'Quarterly');
fprintf('  Sheet  2/16: Quarterly\n');

% -------------------------------------------------------------------------
% Sheet 3: Daily_PortfolioValue
% -------------------------------------------------------------------------
bond_ccy_hdrs = cellfun(@(c) sprintf('Bonds_%s [EUR]', c), dm.cName(:)', 'UniformOutput', false);

% V_EUR breakdown check: Cash + Components + WIP + Bonds should equal V_EUR
hdrPV = [{'Date', ...
  'V_EUR [EUR]', 'V_SEK [SEK]', ...
  'Cash [EUR]', 'Components [EUR]', 'WIP [EUR]', 'Bonds_total [EUR]'}, bond_ccy_hdrs, ...
  {'V_SEK_CompRates [SEK] (Run3 — prior-year quarterly avg rates)', ...
  'V_SEK_TranslConst [SEK] (Run4 — actual trans x frozen EUR/SEK)', ...
  'V_SEK_LYRates [SEK] (Run5 — last-year same-date rates)', ...
  'V_SEK_TranslLY [SEK] (Run6 — actual trans x last-year EUR/SEK)', ...
  'EUR/SEK_CompRate'}];
pvData = [dateStrs, num2cell([dr.V_EUR, dr.V_SEK, ...
  sum(cashEUR,2), compEUR, wipEUR, bondsEUR, bondsByCcyEUR, ...
  dr.V_SEK_const, dr.V_SEK_transl_const, dr.V_SEK_LY, dr.V_SEK_transl_LY, ...
  dr.f_EUR_SEK_comp])];
writecell([hdrPV; pvData], xlFile, 'Sheet', 'Daily_PortfolioValue');
fprintf('  Sheet  3/16: Daily_PortfolioValue\n');

% -------------------------------------------------------------------------
% Sheet 4: Daily_FXImpact
% -------------------------------------------------------------------------
hdrFX = {'Date', ...
  'TI_Bonds_daily [SEK] (Eq.4.45 — AR/AP only)', ...
  'TI_BondsBOM_daily [SEK] (Bonds+BOM forward exposure)', ...
  'OCI_daily [SEK] (Eq.4.46 — Translation FX)', ...
  'CC_total_daily [SEK] (Eq.4.47 — Constant-currency total)', ...
  'CC_trans_CompRates_daily [SEK] (Run3 vs Run4)', ...
  'CC_transl_CompRates_daily [SEK] (Run4 vs Run1)', ...
  'CC_total_LYRates_daily [SEK] (Run5 vs Run1)', ...
  'CC_trans_LYRates_daily [SEK] (Run5 vs Run6)', ...
  'CC_transl_LYRates_daily [SEK] (Run6 vs Run1)', ...
  'TI_Bonds_cumulative [SEK]', ...
  'TI_BondsBOM_cumulative [SEK]', ...
  'OCI_cumulative [SEK]', ...
  'CC_total_cumulative [SEK]', ...
  'CC_trans_CompRates_cumulative [SEK]', ...
  'CC_transl_CompRates_cumulative [SEK]', ...
  'CC_total_LYRates_cumulative [SEK]', ...
  'CC_trans_LYRates_cumulative [SEK]', ...
  'CC_transl_LYRates_cumulative [SEK]'};
fxData = [dateStrs, num2cell([ ...
  dr.dFX_trans, dr.dFX_trans_BOM, dr.dFX_transl, dr.dFX_cc, ...
  dr.dFX_trans_CC, dr.dFX_transl_CC, ...
  dr.dFX_cc_LY_total, dr.dFX_trans_CC_LY, dr.dFX_transl_CC_LY, ...
  cumsum(dr.dFX_trans), cumsum(dr.dFX_trans_BOM), cumsum(dr.dFX_transl), cumsum(dr.dFX_cc), ...
  cumsum(dr.dFX_trans_CC), cumsum(dr.dFX_transl_CC), ...
  cumsum(dr.dFX_cc_LY_total), cumsum(dr.dFX_trans_CC_LY), cumsum(dr.dFX_transl_CC_LY)])];
writecell([hdrFX; fxData], xlFile, 'Sheet', 'Daily_FXImpact');
fprintf('  Sheet  4/16: Daily_FXImpact\n');

% -------------------------------------------------------------------------
% Sheet 5: Daily_PAMTerms — all PAM P&L decomposition terms
% -------------------------------------------------------------------------
hdrPAM = {'Date', ...
  'dI [EUR] (Interest on cash)', ...
  'dMf [EUR] (FX effect on cash holdings, h·R·df)', ...
  'dDf_other [EUR] (FX on non-bond dividends — should be ~0 for this portfolio)', ...
  'dDf_arApBonds [EUR] (Settlement-day FX on AR/AP bonds — reclassified to TI)', ...
  'dC [EUR] (Transaction costs — negative)', ...
  'dPtheta [EUR] (Term-structure carry)', ...
  'dPxi [EUR] (Linear FX/IR risk factor effects)', ...
  'dPq [EUR] (Quadratic FX/IR risk factor effects)', ...
  'dPa [EUR] (Taylor approximation residual)', ...
  'dPI [EUR] (Interest-rate precision residual)', ...
  'dPf [EUR] (FX revaluation of foreign-ccy holdings at prev prices)', ...
  'dPc [EUR] (Price-FX cross term)', ...
  'dFX_trans_EUR [EUR] (Trans FX in EUR — Bonds only = dPf+dPc+dSettlFX, Eq.4.45)', ...
  'dFX_trans_BOM_EUR [EUR] (Trans FX in EUR — Bonds+BOM = dPf+dPxi_FX+dPc+dSettlFX)'};
pamData = [dateStrs, num2cell([ ...
  dr.dVdI, dr.dVhRdf, dr.dVhDdf_other, dr.dVhDdf_arApBonds, dr.dVdC, ...
  dr.dVhdPtf, dr.dVhdPxif, dr.dVhdPqf, dr.dVhdepsaf, dr.dVhdepsIf, ...
  dr.dVhPtotdf, dr.dVhdepsf, dr.dFX_trans_EUR, dr.dFX_trans_BOM_EUR])];
writecell([hdrPAM; pamData], xlFile, 'Sheet', 'Daily_PAMTerms');
fprintf('  Sheet  5/16: Daily_PAMTerms\n');

% -------------------------------------------------------------------------
% Sheet 6: Daily_FXRates
% -------------------------------------------------------------------------
hdrRates = [{'Date'}, ...
  strcat(dm.cName', '_to_EUR'), ...
  strcat(dm.cName', '_to_SEK')];
ratesData = [dateStrs, num2cell([ratesEUR, ratesSEK])];
writecell([hdrRates; ratesData], xlFile, 'Sheet', 'Daily_FXRates');
fprintf('  Sheet  6/16: Daily_FXRates\n');

% -------------------------------------------------------------------------
% Sheet 7: Daily_CashHoldings
% -------------------------------------------------------------------------
hdrCash = [{'Date'}, ...
  strcat(dm.cName', '_cash_local'), ...
  strcat(dm.cName', '_cash_EUR_equiv')];
cashData = [dateStrs, num2cell([dr.hC, cashEUR])];
writecell([hdrCash; cashData], xlFile, 'Sheet', 'Daily_CashHoldings');
fprintf('  Sheet  7/16: Daily_CashHoldings\n');

% -------------------------------------------------------------------------
% Sheet 8: Daily_Instruments
% -------------------------------------------------------------------------
hdrInstr = [{'Date'}, strcat(dm.cName', '_instruments_EUR_equiv')];
instrData = [dateStrs, num2cell(hIPbar_byCcy)];
writecell([hdrInstr; instrData], xlFile, 'Sheet', 'Daily_Instruments');
fprintf('  Sheet  8/16: Daily_Instruments\n');

% -------------------------------------------------------------------------
% Sheet 9: Daily_Transactions
% -------------------------------------------------------------------------
hdrTx = [{'Date'}, ...
  strcat(dm.cName', '_buys_EUR_equiv'), ...
  strcat(dm.cName', '_sells_EUR_equiv')];
txData = [dateStrs, num2cell([buyByCcy, sellByCcy])];
writecell([hdrTx; txData], xlFile, 'Sheet', 'Daily_Transactions');
fprintf('  Sheet  9/16: Daily_Transactions\n');

% -------------------------------------------------------------------------
% Sheet 10: PortfolioSummary — EUR decomposition check
% -------------------------------------------------------------------------
hdrPS = {'Date', 'V_EUR [EUR]', 'V_SEK [SEK]', ...
  'Cash_total_EUR (sum across currencies)', ...
  'Instruments_total_EUR (sum across currencies)', ...
  'Cash + Instruments (should equal V_EUR)'};
hC_total_EUR     = sum(cashEUR, 2);
hIPbar_total_EUR = sum(hIPbar_byCcy, 2);
psData = [dateStrs, num2cell([dr.V_EUR, dr.V_SEK, ...
  hC_total_EUR, hIPbar_total_EUR, hC_total_EUR + hIPbar_total_EUR])];
writecell([hdrPS; psData], xlFile, 'Sheet', 'PortfolioSummary');
fprintf('  Sheet 10/16: PortfolioSummary\n');

% -------------------------------------------------------------------------
% Sheet 11: PurchaseOrders
% -------------------------------------------------------------------------
hdrPO = {'PurchaseOrderNumber', 'ItemNumber', 'TransactionCode', ...
  'Currency', 'Quantity', 'AccountingDate', 'DueDate', ...
  'LineAmount_OrderCurrency', 'CurrencyIndex'};
nPO = length(dc.p.purchaseOrderNumber);
poData = [num2cell(dc.p.purchaseOrderNumber(:)), ...
  num2cell(dc.p.itemNumber(:)), ...
  num2cell(dc.p.transactionCode(:)), ...
  dc.p.currency(:), ...
  num2cell(dc.p.invoicedQuantityAlternateUM(:)), ...
  dn2s(dc.p.accountingDate(:)), ...
  dn2s(dc.p.dueDate(:)), ...
  num2cell(dc.p.lineAmountOrderCurrency(:)), ...
  num2cell(dc.p.iCur(:))];
writecell([hdrPO; poData], xlFile, 'Sheet', 'PurchaseOrders');
fprintf('  Sheet 11/16: PurchaseOrders (%d rows)\n', nPO);

% -------------------------------------------------------------------------
% Sheet 12: StockTransactions
% -------------------------------------------------------------------------
hdrST = {'ItemNumber', 'TransactionType (25=procurement, 90=shrinkage)', ...
  'EntryDate', 'Quantity', 'NewOnHandBalance', 'ImpliedOnHandBalance', ...
  'OrderNumber', 'PurchaseOrderIndex'};
nST = length(dc.s.itemNumber);
stData = [num2cell(dc.s.itemNumber(:)), ...
  num2cell(dc.s.stockTransactionType(:)), ...
  dn2s(dc.s.entryDate(:)), ...
  num2cell(dc.s.transactionQuantityBasicUM(:)), ...
  num2cell(dc.s.newOnHandBalance(:)), ...
  num2cell(dc.s.impliedOnHandBalance(:)), ...
  num2cell(dc.s.orderNumber(:)), ...
  num2cell(dc.s.jPurchaseOrder(:))];
writecell([hdrST; stData], xlFile, 'Sheet', 'StockTransactions');
fprintf('  Sheet 12/16: StockTransactions (%d rows)\n', nST);

% -------------------------------------------------------------------------
% Sheet 13: AccountsReceivable
% -------------------------------------------------------------------------
hdrAR = {'InvoiceNumber', 'TransactionCode (10=invoice, 20=payment)', ...
  'AccountingDate', 'DueDate', 'ForeignCurrencyAmount', 'Currency', ...
  'CurrencyIndex', 'BondAssetIndex'};
nAR = length(dc.a.invoiceNumber);
arData = [num2cell(dc.a.invoiceNumber(:)), ...
  num2cell(dc.a.transactionCode(:)), ...
  dn2s(dc.a.accountingDate(:)), ...
  dn2s(dc.a.dueDate(:)), ...
  num2cell(dc.a.foreignCurrencyAmount(:)), ...
  dc.a.currency(:), ...
  num2cell(dc.a.iCur(:)), ...
  num2cell(dc.a.jBond(:))];
writecell([hdrAR; arData], xlFile, 'Sheet', 'AccountsReceivable');
fprintf('  Sheet 13/16: AccountsReceivable (%d rows)\n', nAR);

% -------------------------------------------------------------------------
% Sheet 14: AccountsPayable
% -------------------------------------------------------------------------
hdrAP = {'InvoiceNumber', 'TransactionCode (10=order, 20=payment)', ...
  'AccountingDate', 'DueDate', 'ForeignCurrencyAmount', 'Currency', ...
  'CurrencyIndex', 'BondAssetIndex'};
nAP = length(dc.ap.invoiceNumber);
apData = [num2cell(dc.ap.invoiceNumber(:)), ...
  num2cell(dc.ap.transactionCode(:)), ...
  dn2s(dc.ap.accountingDate(:)), ...
  dn2s(dc.ap.dueDate(:)), ...
  num2cell(dc.ap.foreignCurrencyAmount(:)), ...
  dc.ap.currency(:), ...
  num2cell(dc.ap.iCur(:)), ...
  num2cell(dc.ap.jBond(:))];
writecell([hdrAP; apData], xlFile, 'Sheet', 'AccountsPayable');
fprintf('  Sheet 14/16: AccountsPayable (%d rows)\n', nAP);

% -------------------------------------------------------------------------
% Sheet 15: Sales — sorted by order date (mfgStart)
% -------------------------------------------------------------------------
nSA = length(dc.sa.invoiceNumber);

% Extract invoice date (transactionCode=10) and payment date (transactionCode=20)
% AR rows are stored in pairs: odd=invoice, even=payment
arInvoiceDates = dc.a.accountingDate(dc.a.transactionCode == 10);
arPaymentDates = dc.a.accountingDate(dc.a.transactionCode == 20);

% Order date = mfgStart (productOrderDate, one per product)
orderDates = dc.productOrderDate(1:nSA);

% Sort by order date
[~, saSort] = sort(orderDates);

hdrSA = {'InvoiceNumber', 'OrderDate (mfgStart)', 'InvoiceDate (mfgFinish+7)', ...
  'PaymentDate', 'Currency', ...
  'ForeignCurrencyAmount', 'LineAmount_LocalCurrency_EUR', 'CostPrice_EUR', ...
  'GrossMargin_EUR', 'GrossMargin_pct', 'CurrencyIndex'};
grossMarginEUR = dc.sa.lineAmountLocalCurrency(:) - dc.sa.costPrice(:);
grossMarginPct = 100 * grossMarginEUR ./ dc.sa.lineAmountLocalCurrency(:);
saData = [num2cell(dc.sa.invoiceNumber(saSort)), ...
  dn2s(orderDates(saSort)), ...
  dn2s(arInvoiceDates(saSort)), ...
  dn2s(arPaymentDates(saSort)), ...
  dc.sa.currency(saSort), ...
  num2cell(dc.sa.foreignCurrencyAmount(saSort)), ...
  num2cell(dc.sa.lineAmountLocalCurrency(saSort)), ...
  num2cell(dc.sa.costPrice(saSort)), ...
  num2cell(grossMarginEUR(saSort)), ...
  num2cell(grossMarginPct(saSort)), ...
  num2cell(dc.sa.iCur(saSort))];
writecell([hdrSA; saData], xlFile, 'Sheet', 'Sales');
fprintf('  Sheet 15/18: Sales (%d rows, sorted by order date)\n', nSA);

% -------------------------------------------------------------------------
% Sheet 16: BOM
% -------------------------------------------------------------------------
hdrBOM = {'Product', 'ComponentNumber', 'Quantity', ...
  'ReferenceOrderNumber', 'ReportingDate', 'ActualFinishDate', ...
  'CostPrice_EUR', 'CostPriceValue_EUR', 'ProductIndex'};
nBOM = length(dc.b.product);
bomData = [num2cell(dc.b.product(:)), ...
  num2cell(dc.b.componentNumber(:)), ...
  num2cell(dc.b.quantity(:)), ...
  num2cell(dc.b.referenceOrderNumber(:)), ...
  dn2s(dc.b.reportingDate(:)), ...
  dn2s(dc.b.actualFinishDate(:)), ...
  num2cell(dc.b.costPrice(:)), ...
  num2cell(dc.b.CostPriceValue(:)), ...
  num2cell(dc.b.iProduct(:))];
writecell([hdrBOM; bomData], xlFile, 'Sheet', 'BOM');
fprintf('  Sheet 16/18: BOM (%d rows, sorted by product ID)\n', nBOM);

% -------------------------------------------------------------------------
% Sheet 17: Quarterly_TI — Transaction Impact quarterly comparison
% -------------------------------------------------------------------------
hdrTI = {'Quarter', ...
  'PAM_TI_Bonds [SEK] (Eq.4.45)', ...
  'PAM_TI_BondsBOM [SEK]', ...
  'Method1_TI [SEK]', ...
  'Method2_Monthly_TI [SEK]', ...
  'Cumul_PAM_Bonds [SEK]', ...
  'Cumul_PAM_BondsBOM [SEK]', ...
  'Cumul_Method1 [SEK]', ...
  'Cumul_Method2_Monthly [SEK]', ...
  'Diff_M1_vs_PAM_Bonds [SEK]', ...
  'Diff_M2m_vs_PAM_Bonds [SEK]', ...
  'Diff_M1_vs_PAM_BOM [SEK]', ...
  'Diff_M2m_vs_PAM_BOM [SEK]'};
tiData = [qLabels, num2cell([ ...
  TI_q,  TI_BOM_q,  m1TI_q,  m2TI_m_q, ...
  cumsum(TI_q), cumsum(TI_BOM_q), cumsum(m1TI_q), cumsum(m2TI_m_q), ...
  m1TI_q - TI_q,   m2TI_m_q - TI_q, ...
  m1TI_q - TI_BOM_q, m2TI_m_q - TI_BOM_q])];
tiTotRow = [{'TOTAL'}, num2cell([ ...
  sum(TI_q), sum(TI_BOM_q), sum(m1TI_q), sum(m2TI_m_q), ...
  sum(TI_q), sum(TI_BOM_q), sum(m1TI_q), sum(m2TI_m_q), ...
  sum(m1TI_q)-sum(TI_q),   sum(m2TI_m_q)-sum(TI_q), ...
  sum(m1TI_q)-sum(TI_BOM_q), sum(m2TI_m_q)-sum(TI_BOM_q)])];
writecell([hdrTI; tiData; tiTotRow], xlFile, 'Sheet', 'Quarterly_TI');
fprintf('  Sheet 17/18: Quarterly_TI\n');

% -------------------------------------------------------------------------
% Sheet 18: Quarterly_OCI — Translation (OCI) quarterly comparison
% -------------------------------------------------------------------------
hdrOCI = {'Quarter', ...
  'PAM_OCI [SEK] (Eq.4.46)', ...
  'Method1_OCI [SEK]', ...
  'Method2_Monthly_OCI [SEK]', ...
  'Cumul_PAM_OCI [SEK]', ...
  'Cumul_Method1_OCI [SEK]', ...
  'Cumul_Method2_Monthly_OCI [SEK]', ...
  'Diff_M1_vs_PAM [SEK]', ...
  'Diff_M2m_vs_PAM [SEK]'};
ociData = [qLabels, num2cell([ ...
  OCI_q, m1OCI_q, m2OCI_m_q, ...
  cumsum(OCI_q), cumsum(m1OCI_q), cumsum(m2OCI_m_q), ...
  m1OCI_q - OCI_q,  m2OCI_m_q - OCI_q])];
ociTotRow = [{'TOTAL'}, num2cell([ ...
  sum(OCI_q), sum(m1OCI_q), sum(m2OCI_m_q), ...
  sum(OCI_q), sum(m1OCI_q), sum(m2OCI_m_q), ...
  sum(m1OCI_q)-sum(OCI_q), sum(m2OCI_m_q)-sum(OCI_q)])];
writecell([hdrOCI; ociData; ociTotRow], xlFile, 'Sheet', 'Quarterly_OCI');
fprintf('  Sheet 18/18: Quarterly_OCI\n');

% -------------------------------------------------------------------------
% Sheet 19: Sensitivity_NoDiscount
%   Compares standard PAM TI (discounted bonds) against PAM TI with all
%   discount factors removed (bonds valued at face value × FX rate).
%   Purpose: isolates the contribution of PV discounting to the PAM–M1 gap.
%   Both PAM series include settlement-day FX (the thesis assumes no FX on
%   dividends; AR/AP maturity payments are commercial settlements, not dividends).
%   Columns: PAM Bonds | PAM BOM | M1 | M2m | PAM ND | PAM BOM ND |
%            Delta M1 vs PAM ND | Delta M1 vs PAM BOM ND
% -------------------------------------------------------------------------
if haveSens
  hdrSens = {'Quarter', ...
    'PAM_TI_Bonds [SEK]',        'PAM_TI_BondsBOM [SEK]', ...
    'Method1_TI [SEK]',          'Method2_Monthly_TI [SEK]', ...
    'PAM_TI_Bonds_NoDisc [SEK]', 'PAM_TI_BondsBOM_NoDisc [SEK]', ...
    'Delta_M1_vs_PAM_ND [SEK]',  'Delta_M1_vs_PAM_BOM_ND [SEK]'};
  sensData = [qLabels, num2cell([ ...
    TI_q,    TI_BOM_q,    m1TI_q, m2TI_m_q, ...
    TI_nd_q, TI_BOM_nd_q, ...
    m1TI_q - TI_nd_q, m1TI_q - TI_BOM_nd_q])];
  sensTotRow = [{'TOTAL'}, num2cell([ ...
    sum(TI_q),    sum(TI_BOM_q),    sum(m1TI_q), sum(m2TI_m_q), ...
    sum(TI_nd_q), sum(TI_BOM_nd_q), ...
    sum(m1TI_q) - sum(TI_nd_q), sum(m1TI_q) - sum(TI_BOM_nd_q)])];
  writecell([hdrSens; sensData; sensTotRow], xlFile, 'Sheet', 'Sensitivity_NoDiscount');
  fprintf('  Sheet 19/19: Sensitivity_NoDiscount\n');
else
  fprintf('  Sheet 19: Sensitivity_NoDiscount skipped (runSensitivityNoDiscount = false or dr_nd missing)\n');
end

% =========================================================================
% POST-PROCESS: Apply number formatting via Excel COM
%   Format '# ##0'  — space as thousands separator, 0 decimals
%   This format code avoids the Swedish-locale comma ambiguity that
%   '#,##0' causes, and works on any Windows locale.
%   Sheet Daily_FXRates gets '0.0000' (rates need 4 decimal places).
% =========================================================================
fprintf('Applying number formatting...\n');
xlFile_abs = char(java.io.File(xlFile).getCanonicalPath());
try
  % Kill any stray Excel process left from a previous crashed run
  system('taskkill /F /IM EXCEL.EXE /T 2>nul');
  pause(1.5);

  xlApp = actxserver('Excel.Application');
  xlApp.Visible       = false;
  xlApp.DisplayAlerts = false;

  try
    wb = xlApp.Workbooks.Open(xlFile_abs);

    for si = 1:wb.Sheets.Count
      sh = wb.Sheets.Item(si);
      if strcmp(sh.Name, 'Daily_FXRates')
        % FX rate values need 4 decimal places.
        % Applying to UsedRange is fine — text cells (dates, headers)
        % are unaffected by number formats.
        sh.UsedRange.NumberFormat = '0.0000';
      else
        % Space as thousands separator, 0 decimals.
        % Text cells (date strings, headers) are unaffected.
        sh.UsedRange.NumberFormat = '# ##0';
      end
    end

    wb.Save();
    wb.Close(false);
    xlApp.Quit();
    fprintf('  Number formatting applied (space thousands separator).\n');

  catch ME2
    try; wb.Close(false); catch; end  %#ok<NOEFF>
    try; xlApp.Quit();    catch; end  %#ok<NOEFF>
    warning('runExcelExport:comFormat', ...
      'COM formatting failed: %s', ME2.message);
  end

catch ME
  warning('runExcelExport:comStart', ...
    'Excel COM not available — numbers written without formatting. (%s)', ME.message);
end

fprintf('\nDone. Excel written: %s\n', xlFile);
fprintf(['Sheets: Annual | Quarterly | Daily_PortfolioValue | Daily_FXImpact |\n' ...
         '        Daily_PAMTerms | Daily_FXRates | Daily_CashHoldings |\n' ...
         '        Daily_Instruments | Daily_Transactions | PortfolioSummary |\n' ...
         '        PurchaseOrders | StockTransactions | AccountsReceivable |\n' ...
         '        AccountsPayable | Sales | BOM |\n' ...
         '        Quarterly_TI | Quarterly_OCI']);
if haveSens
  fprintf(' | Sensitivity_NoDiscount\n');
else
  fprintf('\n  (Sensitivity_NoDiscount sheet skipped — set runSensitivityNoDiscount = true to enable)\n');
end

% =========================================================================
% LOCAL HELPERS  (must come after all script code)
% =========================================================================

function C = fmtK(M, dec)
% fmtK  Format a numeric matrix as a cell array of strings.
%   fmtK(M)        — rounded integers with space thousands separator
%   fmtK(M, dec)   — dec decimal places, comma as decimal (Swedish style)
%
% Examples:
%   fmtK(1234567)     →  {'1 234 567'}
%   fmtK(-42000.9)    →  {'-42 001'}
%   fmtK(11.2543, 2)  →  {'11,25'}
%   fmtK(0.6312, 4)   →  {'0,6312'}
%
% Works entirely in MATLAB — no Excel COM, no locale dependency.
if nargin < 2, dec = 0; end
M = double(M);
C = cell(size(M));
for i = 1:numel(M)
  x = M(i);
  if isnan(x) || isinf(x), C{i} = '0'; continue; end
  neg = (x < 0);
  x   = abs(x);
  if dec == 0
    x  = round(x);
    s  = addThousandsSep(sprintf('%d', x));
  else
    xi = floor(x);
    xd = round((x - xi) * 10^dec);
    if xd >= 10^dec, xi = xi + 1; xd = 0; end   % carry
    si = addThousandsSep(sprintf('%d', xi));
    sd = sprintf(['%0' num2str(dec) 'd'], xd);
    s  = [si ',' sd];
  end
  if neg && ~strcmp(strrep(strrep(s,' ',''), ',', ''), '0')
    s = ['-' s];
  end
  C{i} = s;
end
end

function s = addThousandsSep(s)
% addThousandsSep  Insert space every 3 digits from the right.
%   Works by reversing the string, inserting after every 3rd digit when
%   another digit follows, then reversing back.
%   '1234567'  →  '1 234 567'
%   '123'      →  '123'
s = fliplr(regexprep(fliplr(s), '(\d{3})(?=\d)', '$1 '));
end
