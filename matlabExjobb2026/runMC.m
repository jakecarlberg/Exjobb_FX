% runMC  Monte Carlo driver for PAM FX benchmark analysis
%
% Runs K iterations of the full pipeline:
%   createMatFilesSim -> createDataCompany -> buildPA -> performanceAttribution
%
% Market data (dm) is loaded once and kept fixed across all iterations,
% consistent with the thesis (Section 4.2.1): stochastic transaction
% datasets, fixed historical exchange rate series 2005-2025.
%
% Results are stored per quarter so the MC produces a distribution of
% quarterly PAM FX outcomes (not just a full-period total).
%
% Usage:
%   runMC              % default K=100
%   K = 500; runMC     % override before running

% =========================================================================
% SETTINGS
% =========================================================================
if ~exist('K',    'var'), K    = 100; end

settings.dataFolder         = 'simulatedData';
settings.bomPricing         = 'StochasticPrices';
settings.curFunctional      = 'EUR';
settings.startDate          = datenum(2007,1,1);  % Change to 2005 when FX data is available
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
% INR dropped due to limited yield curve history (starts Nov 2010)
settings.currencies         = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

marketDataSet = 'reutersZero';

% =========================================================================
% LOAD MARKET DATA ONCE  (fixed across MC iterations)
% =========================================================================
if ~exist('dm', 'var')
  fprintf('Loading market data...\n');
  dm = createDataMarket(marketDataSet, settings);
  fprintf('Market data loaded: %d dates, %d currencies\n\n', ...
    length(dm.dates), length(dm.cName));
end

% =========================================================================
% QUARTERLY PERIOD BOUNDARIES  (shared with computeFXGains)
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;

% Pre-compute which dm date indices belong to each quarter
quarterIdx = cell(nPeriods, 1);
for p = 1:nPeriods
  quarterIdx{p} = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
end

% =========================================================================
% PRE-ALLOCATE RESULT ARRAYS  [K x nPeriods]
% =========================================================================
mc.FX_trans     = nan(K, nPeriods);   % Transactional FX per quarter (Eq. 4.45)
mc.FX_transl    = nan(K, nPeriods);   % Translation FX per quarter   (Eq. 4.46)
mc.FX_cc        = nan(K, nPeriods);   % Constant-currency per quarter (Eq. 4.47)
mc.FX_trans_CC  = nan(K, nPeriods);   % CC transaction component
mc.FX_transl_CC = nan(K, nPeriods);   % CC translation component
mc.FX_cc_total  = nan(K, nPeriods);   % CC total (trans + transl)
mc.seeds        = (1:K)';
mc.periodDates  = periodDates;

% =========================================================================
% MONTE CARLO LOOP
% =========================================================================
fprintf('Starting Monte Carlo: K=%d, nQuarters=%d\n\n', K, nPeriods);
tStart = tic;

for k = 1:K

  createMatFilesSim(dm, k, false);

  try
    dc = createDataCompany(dm, settings);
    dp = buildPA(dm, dc);
    dr = performanceAttribution(dm, dc, dp, false);

    % Aggregate daily PAM contributions to quarters
    for p = 1:nPeriods
      idx = quarterIdx{p};
      if ~isempty(idx)
        mc.FX_trans(k,  p) = sum(dr.dFX_trans(idx));
        mc.FX_transl(k, p) = sum(dr.dFX_transl(idx));
        mc.FX_cc(k,     p) = sum(dr.dFX_cc(idx));
      end
    end
    % CC decomposition components — already at quarterly resolution in dr
    mc.FX_trans_CC(k,  :) = dr.FX_trans_CC_quarterly(:)';
    mc.FX_transl_CC(k, :) = dr.FX_transl_CC_quarterly(:)';
    mc.FX_cc_total(k,  :) = dr.FX_cc_total_quarterly(:)';

  catch ME
    fprintf('  [iter %d] ERROR: %s\n', k, ME.message);
  end

  if mod(k, max(1, round(K/10))) == 0
    elapsed = toc(tStart);
    eta     = elapsed / k * (K - k);
    fprintf('  %4d / %4d  (%.0fs elapsed, ~%.0fs remaining)\n', k, K, elapsed, eta);
  end

end

fprintf('\nMonte Carlo complete. Total time: %.1fs\n', toc(tStart));

% =========================================================================
% SUMMARY STATISTICS  (across iterations, per quarter)
% =========================================================================
valid = ~any(isnan(mc.FX_trans), 2) & ~any(isnan(mc.FX_cc_total), 2);
nValid = sum(valid);

fprintf('\n=== PAM FX Benchmarks: mean per quarter across %d iterations (SEK) ===\n', nValid);
fprintf('%-12s %14s %14s %14s\n', 'Quarter end', 'Transactional', 'Translation', 'Const-cur');
fprintf('%s\n', repmat('-', 1, 58));
for p = 1:nPeriods
  fprintf('%-12s %14.0f %14.0f %14.0f\n', ...
    datestr(periodDates(p+1), 'yyyy-mm-dd'), ...
    mean(mc.FX_trans(valid, p)), ...
    mean(mc.FX_transl(valid, p)), ...
    mean(mc.FX_cc(valid, p)));
end

fprintf('\n=== Full-period totals (sum of quarters) ===\n');
names  = {'Transactional (Eq.4.45)', 'Translation   (Eq.4.46)', 'Const-currency(Eq.4.47)'};
fields = {'FX_trans', 'FX_transl', 'FX_cc'};
fprintf('%-28s %12s %12s %12s %12s %12s\n', '', 'Mean', 'Std', 'P5', 'Median', 'P95');
fprintf('%s\n', repmat('-', 1, 80));
for f = 1:3
  x = sum(mc.(fields{f})(valid, :), 2);
  fprintf('%-28s %12.0f %12.0f %12.0f %12.0f %12.0f\n', names{f}, ...
    mean(x), std(x), prctile(x,5), median(x), prctile(x,95));
end

% =========================================================================
% ANNUAL SUMMARY  (Q1+Q2+Q3+Q4 per calendar year, mean over valid iterations)
% =========================================================================
qEndDates = periodDates(2:end);          % end-date of each quarter
[qYears, ~, ~] = datevec(qEndDates);
uniqueYears = unique(qYears);
nYears      = length(uniqueYears);

% For each year: sum the quarterly MC means within the year.
% Equivalent to: mean over valid iters of (sum of quarters in year).
TI_annual       = zeros(nYears, 1);
OCI_annual      = zeros(nYears, 1);
CCt_annual      = zeros(nYears, 1);
CCtr_annual     = zeros(nYears, 1);
CCtl_annual     = zeros(nYears, 1);

for y = 1:nYears
  qMask = (qYears == uniqueYears(y));
  TI_annual(y)   = mean(sum(mc.FX_trans(valid,     qMask), 2));
  OCI_annual(y)  = mean(sum(mc.FX_transl(valid,    qMask), 2));
  CCt_annual(y)  = mean(sum(mc.FX_cc_total(valid,  qMask), 2));
  CCtr_annual(y) = mean(sum(mc.FX_trans_CC(valid,  qMask), 2));
  CCtl_annual(y) = mean(sum(mc.FX_transl_CC(valid, qMask), 2));
end

% Sanity check: CC_trans + CC_transl == CC_total (per year)
for y = 1:nYears
  err = abs(CCtr_annual(y) + CCtl_annual(y) - CCt_annual(y));
  assert(err < 1e-6, 'CC annual decomposition mismatch for year %d (err=%.2e)', ...
    uniqueYears(y), err);
end

fprintf('\n=== PAM — Annual Results (mean over %d iterations, SEK) ===\n', nValid);
fprintf('%-6s %14s %14s %14s %14s %14s\n', ...
  'Year', 'TI', 'OCI', 'CC_total', 'CC_trans', 'CC_transl');
fprintf('%s\n', repmat('-', 1, 82));
for y = 1:nYears
  fprintf('%-6d %14.0f %14.0f %14.0f %14.0f %14.0f\n', ...
    uniqueYears(y), TI_annual(y), OCI_annual(y), ...
    CCt_annual(y), CCtr_annual(y), CCtl_annual(y));
end
fprintf('%s\n', repmat('-', 1, 82));
fprintf('%-6s %14.0f %14.0f %14.0f %14.0f %14.0f\n', 'TOTAL', ...
  sum(TI_annual), sum(OCI_annual), sum(CCt_annual), ...
  sum(CCtr_annual), sum(CCtl_annual));

% =========================================================================
% PLOTS
% =========================================================================
qLabels = datestr(periodDates(2:end), 'yyyy-Qq');

figure(10); clf;
subplot(3,1,1);
boxplot(mc.FX_trans(valid,:));  set(gca,'XTickLabel',[]); ylabel('SEK');
title('Transactional FX per quarter (Eq.4.45)');

subplot(3,1,2);
boxplot(mc.FX_transl(valid,:)); set(gca,'XTickLabel',[]); ylabel('SEK');
title('Translation FX per quarter (Eq.4.46)');

subplot(3,1,3);
boxplot(mc.FX_cc(valid,:));     ylabel('SEK');
title('Constant-currency FX per quarter (Eq.4.47)');

sgtitle(sprintf('PAM FX Benchmarks — Monte Carlo (K=%d)', nValid));
