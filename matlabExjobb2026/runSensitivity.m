% runSensitivity  Timing-parameter sensitivity sweep
%
% Varies each of 4 timing parameters from Table 4.7 independently while the
% others are held at baseline:
%   procLead  - procurement lead time (order -> delivery)
%   mfg       - manufacturing duration
%   custPay   - customer payment delay
%   suppPay   - supplier payment delay
%
% For scaling factor s in {0, 0.25, 0.5, 0.75, 1}, the swept mean is
%   mu^(s)    = (1 - s) * mu_baseline
%   sigma^(s) = (1 - s) * sigma_baseline    (CV preserved across sweep)
% so s=0 is the baseline and s=1 collapses the parameter to zero.
%
% At each (param, s) cell, runs K MC iterations and computes RMSE / ME
% of each industry method against the relevant PAM benchmark:
%   TI  : PAM bonds (FX_trans)          vs M1, M2 weekly/monthly/quarterly
%   OCI : PAM translation (FX_transl)   vs M1 OCI, M2 OCI variants
%   CC  : PAM BOM flow CC               vs M1 CC, CC avg, CC close, PAM bonds
%
% Outputs:
%   sensitivity_results.mat  - full grid of mc metrics
%   sensitivity_<param>.fig  - RMSE vs s, one line per method, 3 subplots (TI/OCI/CC)
%
% Usage:
%   runSensitivity                 % default K = 50
%   K = 100; runSensitivity        % override K
if ~exist('K', 'var'), K = 10; end

% =========================================================================
% BASELINE TIMING  (must mirror createMatFilesSim defaults)
% =========================================================================
baseline.procLeadMean = 45;  baseline.procLeadStd = 10;
baseline.mfgMean      = 20;  baseline.mfgStd      =  5;
baseline.custPayMean  = 45;  baseline.custPayStd  = 15;
baseline.suppPayMean  = 60;  baseline.suppPayStd  = 15;

% Parameter sweep table:  key | display label | mean-field | std-field
paramSweeps = {
  'procLead',  'Procurement lead time',  'procLeadMean', 'procLeadStd';
  'mfg',       'Manufacturing time',     'mfgMean',      'mfgStd';
  'custPay',   'Customer payment delay', 'custPayMean',  'custPayStd';
  'suppPay',   'Supplier payment delay', 'suppPayMean',  'suppPayStd';
};
scalings = [0, 0.25, 0.5, 0.75, 1];
nParams  = size(paramSweeps, 1);
nScales  = length(scalings);

% =========================================================================
% SETTINGS  (mirror runMC)
% =========================================================================
settings.dataFolder         = 'simulatedData';
settings.bomPricing         = 'DeterministicCashFlows';
settings.curFunctional      = 'EUR';
settings.startDate          = datenum(2007,1,1);
settings.endDate            = datenum(2025,12,31);
settings.usedItemNumbersOrg = [];
settings.usedProductNumbers = [];
settings.currencies         = {'AUD','CAD','CNY','EUR','GBP','SEK','USD','ZAR'};

addpath(fullfile('IndustryMethods'));
addpath(fullfile('IndustryMethods', 'Method1'));
addpath(fullfile('IndustryMethods', 'Method2'));

% =========================================================================
% LOAD MARKET DATA + SANDVIK ARRAYS  (once)
% =========================================================================
if ~exist('dm', 'var') || ~isfield(dm,'cName') || ~isfield(dm,'dates')
  fprintf('Loading market data...\n');
  dm = createDataMarket('reutersZero', settings);
  fprintf('Market data: %d dates, %d currencies\n\n', length(dm.dates), length(dm.cName));
end

sandvikFile = fullfile('marketData', '202605_Sandvik_Data.xlsx');
sandvikArrays.revenueGrowthPct = [NaN, 18.2, NaN(1,19)];
sandvikArrays.grossMarginPct   = [42.5, 43.1, NaN(1,19)];
raw    = readcell(sandvikFile, 'Sheet', 'Income Statement');
revRow = find(cellfun(@(x) ischar(x) && strcmp(x,'Revenue growth, %'), raw(:,1)));
gmRow  = find(cellfun(@(x) ischar(x) && strcmp(x,'Gross Margin'),      raw(:,1)));
for col = 3:21
  v = raw{revRow, col};
  if isnumeric(v) && ~isnan(v), sandvikArrays.revenueGrowthPct(col) = v * 100; end
  v = raw{gmRow,  col};
  if isnumeric(v) && ~isnan(v), sandvikArrays.grossMarginPct(col)   = v * 100; end
end
fprintf('Sandvik data pre-loaded.\n');

% =========================================================================
% QUARTERLY PERIODS
% =========================================================================
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;
quarterIdx  = cell(nPeriods, 1);
for p = 1:nPeriods
  quarterIdx{p} = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
end

% =========================================================================
% PRE-ALLOCATE RESULTS  [nParams x nScales] per metric
% =========================================================================
results.K           = K;
results.scalings    = scalings;
results.paramKeys   = paramSweeps(:,1);
results.paramLabels = paramSweeps(:,2);
results.baseline    = baseline;

methodsTI  = {'M1','M2w','M2m','M2q'};
methodsOCI = {'M1','M2w','M2m','M2q'};
methodsCC  = {'M1_CC','CC_avg','CC_close','PAM_bonds'};

for m = methodsTI
  results.rmse_TI.(m{1}) = nan(nParams, nScales);
  results.me_TI.(m{1})   = nan(nParams, nScales);
end
for m = methodsOCI
  results.rmse_OCI.(m{1}) = nan(nParams, nScales);
  results.me_OCI.(m{1})   = nan(nParams, nScales);
end
for m = methodsCC
  results.rmse_CC.(m{1}) = nan(nParams, nScales);
  results.me_CC.(m{1})   = nan(nParams, nScales);
end

% =========================================================================
% MAIN SWEEP
% =========================================================================
fprintf('\nSensitivity sweep: K=%d, %d params x %d scalings = %d MC runs\n\n', ...
  K, nParams, nScales, nParams*nScales);
tStart = tic;

for pi = 1:nParams
  paramKey   = paramSweeps{pi, 1};
  meanField  = paramSweeps{pi, 3};
  stdField   = paramSweeps{pi, 4};

  for si = 1:nScales
    s = scalings(si);

    % Build timing override (only this param's mean+std are scaled)
    timingOverride = baseline;
    timingOverride.(meanField) = (1 - s) * baseline.(meanField);
    timingOverride.(stdField)  = (1 - s) * baseline.(stdField);

    fprintf('[%s s=%.2f]  mu=%.1f  sigma=%.1f ... ', ...
      paramKey, s, timingOverride.(meanField), timingOverride.(stdField));
    tCell = tic;

    % Pre-allocate per-iteration storage [K x nPeriods]
    PAM_TI   = nan(K, nPeriods);
    PAM_OCI  = nan(K, nPeriods);
    M1_TI    = nan(K, nPeriods);   M1_OCI   = nan(K, nPeriods);
    M2w_TI   = nan(K, nPeriods);   M2w_OCI  = nan(K, nPeriods);
    M2m_TI   = nan(K, nPeriods);   M2m_OCI  = nan(K, nPeriods);
    M2q_TI   = nan(K, nPeriods);   M2q_OCI  = nan(K, nPeriods);
    M1_CC    = nan(K, nPeriods);
    CC_avg   = nan(K, nPeriods);
    CC_close = nan(K, nPeriods);
    fBonds   = nan(K, nPeriods);
    fBOM     = nan(K, nPeriods);

    % Inner MC loop
    iterResults = cell(K, 1);
    parfor k = 1:K
      tk = getCurrentTask();
      if isempty(tk), wFolder = 'simulatedData';
      else,           wFolder = fullfile('simulatedData', sprintf('worker_%d', tk.ID));
      end
      localSettings = settings;
      localSettings.dataFolder = wFolder;

      r = struct( ...
        'PAM_TI',   nan(1,nPeriods), 'PAM_OCI',  nan(1,nPeriods), ...
        'M1_TI',    nan(1,nPeriods), 'M1_OCI',   nan(1,nPeriods), ...
        'M2w_TI',   nan(1,nPeriods), 'M2w_OCI',  nan(1,nPeriods), ...
        'M2m_TI',   nan(1,nPeriods), 'M2m_OCI',  nan(1,nPeriods), ...
        'M2q_TI',   nan(1,nPeriods), 'M2q_OCI',  nan(1,nPeriods), ...
        'M1_CC',    nan(1,nPeriods), 'CC_avg',   nan(1,nPeriods), ...
        'CC_close', nan(1,nPeriods), ...
        'fBonds',   nan(1,nPeriods), 'fBOM',     nan(1,nPeriods));

      try
        createMatFilesSim(dm, k, false, wFolder, sandvikArrays, timingOverride);
        dc = createDataCompany(dm, localSettings);

        dp = buildPA(dm, dc);
        dr = performanceAttribution(dm, dc, dp, false);
        for p = 1:nPeriods
          idx = quarterIdx{p};
          if ~isempty(idx)
            r.PAM_TI(p)  = sum(dr.dFX_trans(idx));
            r.PAM_OCI(p) = sum(dr.dFX_transl(idx));
          end
        end

        bs  = buildBalanceSheet(dm, dc);
        pnl = buildFunctionalPnL(dm, dc, bs);

        m1 = computeMethod1(dm, dc, '', bs, pnl);
        r.M1_TI  = m1.TI(:)';
        r.M1_OCI = m1.OCI(:)';

        m2 = computeMethod2(dm, dc, '', bs, pnl);
        r.M2w_TI = m2.weekly.TI(:)';     r.M2w_OCI = m2.weekly.OCI(:)';
        r.M2m_TI = m2.monthly.TI(:)';    r.M2m_OCI = m2.monthly.OCI(:)';
        r.M2q_TI = m2.quarterly.TI(:)';  r.M2q_OCI = m2.quarterly.OCI(:)';

        P = min(length(m1.cc.M1.quarterly_TI), nPeriods);
        r.M1_CC(1:P)    = (m1.cc.M1.quarterly_TI(1:P)    + m1.cc.M1.quarterly_OCI(1:P))';
        r.CC_avg(1:P)   = (m1.cc.avg.quarterly_TI(1:P)   + m1.cc.avg.quarterly_OCI(1:P))';
        r.CC_close(1:P) = (m1.cc.close.quarterly_TI(1:P) + m1.cc.close.quarterly_OCI(1:P))';

        fcc = performanceAttributionFlowCC(dm, dc, pnl);
        Pf  = min(length(fcc.bonds.total_quarterly), nPeriods);
        r.fBonds(1:Pf) = fcc.bonds.total_quarterly(1:Pf)';
        r.fBOM(1:Pf)   = fcc.BOM.total_quarterly(1:Pf)';
      catch ME
        fprintf(2, '\n  iter %d ERROR: %s\n', k, ME.message);
      end

      iterResults{k} = r;
    end

    % Assemble per-method matrices
    for k = 1:K
      r = iterResults{k};
      if isempty(r), continue; end
      PAM_TI(k,:)   = r.PAM_TI;    PAM_OCI(k,:)  = r.PAM_OCI;
      M1_TI(k,:)    = r.M1_TI;     M1_OCI(k,:)   = r.M1_OCI;
      M2w_TI(k,:)   = r.M2w_TI;    M2w_OCI(k,:)  = r.M2w_OCI;
      M2m_TI(k,:)   = r.M2m_TI;    M2m_OCI(k,:)  = r.M2m_OCI;
      M2q_TI(k,:)   = r.M2q_TI;    M2q_OCI(k,:)  = r.M2q_OCI;
      M1_CC(k,:)    = r.M1_CC;
      CC_avg(k,:)   = r.CC_avg;
      CC_close(k,:) = r.CC_close;
      fBonds(k,:)   = r.fBonds;
      fBOM(k,:)     = r.fBOM;
    end

    % Valid mask: drop iterations with any NaN in critical benchmarks
    valid = ~any(isnan(PAM_TI),2) & ~any(isnan(PAM_OCI),2) & ...
            ~any(isnan(M1_TI),2)  & ~any(isnan(M2m_TI),2) & ...
            ~any(isnan(fBOM),2);

    % Error helpers — flattened across (valid iterations) x (all quarters)
    rmse = @(A,B) sqrt(mean((A(valid,:) - B(valid,:)).^2, 'all'));
    me   = @(A,B) mean(A(valid,:) - B(valid,:), 'all');

    % TI errors (benchmark: PAM_TI = FX_trans, bonds-only)
    results.rmse_TI.M1(pi,si)  = rmse(PAM_TI, M1_TI);   results.me_TI.M1(pi,si)  = me(PAM_TI, M1_TI);
    results.rmse_TI.M2w(pi,si) = rmse(PAM_TI, M2w_TI);  results.me_TI.M2w(pi,si) = me(PAM_TI, M2w_TI);
    results.rmse_TI.M2m(pi,si) = rmse(PAM_TI, M2m_TI);  results.me_TI.M2m(pi,si) = me(PAM_TI, M2m_TI);
    results.rmse_TI.M2q(pi,si) = rmse(PAM_TI, M2q_TI);  results.me_TI.M2q(pi,si) = me(PAM_TI, M2q_TI);

    % OCI errors (benchmark: PAM_OCI = FX_transl)
    results.rmse_OCI.M1(pi,si)  = rmse(PAM_OCI, M1_OCI);   results.me_OCI.M1(pi,si)  = me(PAM_OCI, M1_OCI);
    results.rmse_OCI.M2w(pi,si) = rmse(PAM_OCI, M2w_OCI);  results.me_OCI.M2w(pi,si) = me(PAM_OCI, M2w_OCI);
    results.rmse_OCI.M2m(pi,si) = rmse(PAM_OCI, M2m_OCI);  results.me_OCI.M2m(pi,si) = me(PAM_OCI, M2m_OCI);
    results.rmse_OCI.M2q(pi,si) = rmse(PAM_OCI, M2q_OCI);  results.me_OCI.M2q(pi,si) = me(PAM_OCI, M2q_OCI);

    % CC errors (benchmark: fBOM = PAM BOM flow CC)
    results.rmse_CC.M1_CC(pi,si)     = rmse(fBOM, M1_CC);    results.me_CC.M1_CC(pi,si)     = me(fBOM, M1_CC);
    results.rmse_CC.CC_avg(pi,si)    = rmse(fBOM, CC_avg);   results.me_CC.CC_avg(pi,si)    = me(fBOM, CC_avg);
    results.rmse_CC.CC_close(pi,si)  = rmse(fBOM, CC_close); results.me_CC.CC_close(pi,si)  = me(fBOM, CC_close);
    results.rmse_CC.PAM_bonds(pi,si) = rmse(fBOM, fBonds);   results.me_CC.PAM_bonds(pi,si) = me(fBOM, fBonds);

    fprintf('done (%.0fs)  RMSE: TI/M1=%.1fM  OCI/M1=%.1fM  CC/M1=%.1fM  CC/bonds=%.1fM\n', ...
      toc(tCell), ...
      results.rmse_TI.M1(pi,si)/1e6, results.rmse_OCI.M1(pi,si)/1e6, ...
      results.rmse_CC.M1_CC(pi,si)/1e6, results.rmse_CC.PAM_bonds(pi,si)/1e6);
  end
end

fprintf('\nSensitivity sweep complete. Total time: %.1fs\n\n', toc(tStart));

% =========================================================================
% SAVE
% =========================================================================
save('sensitivity_results.mat', 'results', 'paramSweeps', 'baseline');
fprintf('Results saved to sensitivity_results.mat\n');

% =========================================================================
% CONSOLE SUMMARY  (one table per param, RMSE per method)
% =========================================================================
for pi = 1:nParams
  fprintf('\n=== %s — RMSE in SEK million (rows: methods, cols: scaling s) ===\n', ...
    paramSweeps{pi, 2});
  fprintf('%-14s', 'Method');
  for si = 1:nScales, fprintf('%10s', sprintf('s=%.2f', scalings(si))); end
  fprintf('\n%s\n', repmat('-', 1, 14 + 10*nScales));

  printRMSErow('TI/M1',       results.rmse_TI.M1(pi,:),     nScales);
  printRMSErow('TI/M2w',      results.rmse_TI.M2w(pi,:),    nScales);
  printRMSErow('TI/M2m',      results.rmse_TI.M2m(pi,:),    nScales);
  printRMSErow('TI/M2q',      results.rmse_TI.M2q(pi,:),    nScales);
  printRMSErow('OCI/M1',      results.rmse_OCI.M1(pi,:),    nScales);
  printRMSErow('OCI/M2m',     results.rmse_OCI.M2m(pi,:),   nScales);
  printRMSErow('CC/M1_CC',    results.rmse_CC.M1_CC(pi,:),  nScales);
  printRMSErow('CC/CC_avg',   results.rmse_CC.CC_avg(pi,:), nScales);
  printRMSErow('CC/CC_close', results.rmse_CC.CC_close(pi,:),nScales);
  printRMSErow('CC/bonds',    results.rmse_CC.PAM_bonds(pi,:),nScales);
end

% =========================================================================
% PLOTS — one figure per parameter, three subplots (TI / OCI / CC)
% =========================================================================
cM1    = [0.89 0.10 0.11];  % red
cM2w   = [0.99 0.55 0.24];  % orange
cM2m   = [0.20 0.63 0.17];  % green
cM2q   = [0.55 0.34 0.72];  % purple
cPAM   = [0.12 0.47 0.71];  % blue
cCCavg = [0.60 0.40 0.12];  % brown
cCCcls = [0.84 0.19 0.87];  % pink

% Set up figures folder matching runMC convention
figDir = fullfile(pwd, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end

for pi = 1:nParams
  fh = figure(100 + pi); clf;
  paramLabel = paramSweeps{pi, 2};
  paramKey   = paramSweeps{pi, 1};

  % --- TI subplot ---
  subplot(1,3,1); hold on;
  plot(scalings, results.rmse_TI.M1(pi,:)/1e6,  '-o', 'Color',cM1,  'LineWidth',1.6,'DisplayName','M1');
  plot(scalings, results.rmse_TI.M2w(pi,:)/1e6, '-o', 'Color',cM2w, 'LineWidth',1.6,'DisplayName','M2 weekly');
  plot(scalings, results.rmse_TI.M2m(pi,:)/1e6, '-o', 'Color',cM2m, 'LineWidth',1.6,'DisplayName','M2 monthly');
  plot(scalings, results.rmse_TI.M2q(pi,:)/1e6, '-o', 'Color',cM2q, 'LineWidth',1.6,'DisplayName','M2 quarterly');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('TI'); legend('Location','Best');

  % --- OCI subplot ---
  subplot(1,3,2); hold on;
  plot(scalings, results.rmse_OCI.M1(pi,:)/1e6,  '-o', 'Color',cM1,  'LineWidth',1.6,'DisplayName','M1 OCI');
  plot(scalings, results.rmse_OCI.M2w(pi,:)/1e6, '-o', 'Color',cM2w, 'LineWidth',1.6,'DisplayName','M2 weekly');
  plot(scalings, results.rmse_OCI.M2m(pi,:)/1e6, '-o', 'Color',cM2m, 'LineWidth',1.6,'DisplayName','M2 monthly');
  plot(scalings, results.rmse_OCI.M2q(pi,:)/1e6, '-o', 'Color',cM2q, 'LineWidth',1.6,'DisplayName','M2 quarterly');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('OCI'); legend('Location','Best');

  % --- CC subplot ---
  subplot(1,3,3); hold on;
  plot(scalings, results.rmse_CC.M1_CC(pi,:)/1e6,     '-o', 'Color',cM1,    'LineWidth',1.6,'DisplayName','M1 CC');
  plot(scalings, results.rmse_CC.CC_avg(pi,:)/1e6,    '-o', 'Color',cCCavg, 'LineWidth',1.6,'DisplayName','CC avg');
  plot(scalings, results.rmse_CC.CC_close(pi,:)/1e6,  '-o', 'Color',cCCcls, 'LineWidth',1.6,'DisplayName','CC close');
  plot(scalings, results.rmse_CC.PAM_bonds(pi,:)/1e6, '-o', 'Color',cPAM,   'LineWidth',1.6,'DisplayName','PAM bonds');
  xlabel('Scaling s'); ylabel('RMSE (SEK million)'); grid on;
  title('CC'); legend('Location','Best');

  sgtitle(paramLabel);

  % Apply consistent font sizes to all subplots
  axs = findall(fh, 'Type', 'axes');
  for ai = 1:length(axs)
    axs(ai).FontSize = 9;
    axs(ai).Title.FontSize = 11;
    axs(ai).Title.FontWeight = 'bold';
    axs(ai).XLabel.FontSize = 10;
    axs(ai).YLabel.FontSize = 10;
    if ~isempty(axs(ai).Legend)
      axs(ai).Legend.FontSize = 9;
    end
  end

  % Size and save as PDF
  set(fh, 'Units','centimeters', 'Position',[0 0 24 8]);
  set(fh, 'PaperUnits','centimeters', 'PaperSize',[24 8], 'PaperPositionMode','auto');
  pdfName = fullfile(figDir, sprintf('sensitivity_%s.pdf', paramKey));
  saveas(fh, pdfName);
  fprintf('  Figure saved: %s\n', pdfName);
end

% =========================================================================
% LOCAL FUNCTIONS
% =========================================================================
function printRMSErow(label, row, nScales)
  fprintf('%-14s', label);
  for si = 1:nScales
    fprintf('%10.2f', row(si) / 1e6);
  end
  fprintf('\n');
end
