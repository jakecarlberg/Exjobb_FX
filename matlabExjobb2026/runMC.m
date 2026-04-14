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
settings.startDate          = datenum(2005,1,1);
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
% Thesis currencies only (Table 4.5 + procurement + functional/presentation)
settings.currencies         = {'AUD','CAD','CNY','EUR','GBP','INR','SEK','USD','ZAR'};

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
mc.FX_trans  = nan(K, nPeriods);   % Transactional FX per quarter (Eq. 4.45)
mc.FX_transl = nan(K, nPeriods);   % Translation FX per quarter   (Eq. 4.46)
mc.FX_cc     = nan(K, nPeriods);   % Constant-currency per quarter (Eq. 4.47)
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
valid = ~any(isnan(mc.FX_trans), 2);
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
