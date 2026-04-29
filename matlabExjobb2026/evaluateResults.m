function evaluateResults(mc)
% evaluateResults  Evaluate industry method errors against PAM benchmark.
%
%   evaluateResults(mc)
%
% mc is the struct produced by runMC.m. For each method variant and
% impact type the function computes:
%   - Mean Error (ME)               — systematic bias vs PAM
%   - RMSE                          — overall error magnitude
%   - 95% confidence interval for ME
%   - Standard deviation
%   - KDE plots (overlaid per impact type)
%
% Error definition (eq. error in thesis):
%   epsilon^(p,l)_{m,k} = FX^(p,l)_{m,k} - FX^(p,l)_{PAM,k}
%
% TI errors are computed against two PAM benchmarks (bonds only and bonds+BOM).
% OCI errors are computed against the PAM translation benchmark.
% CC errors are computed against the PAM quarterly-avg-rate CC benchmark.
%
% Errors are pooled across all K iterations and P quarters: N = K x P.

% =========================================================================
% Valid iterations (no NaN in any of the core series)
% =========================================================================
valid = ~any(isnan(mc.M1_TI),     2) & ...
        ~any(isnan(mc.M2m_TI),    2) & ...
        ~any(isnan(mc.FX_trans),   2) & ...
        ~any(isnan(mc.CC_avg_TI),  2);

K = sum(valid);
P = size(mc.M1_TI, 2);
N = K * P;

fprintf('\n');
fprintf('=======================================================================\n');
fprintf('  EVALUATION: Industry Methods vs PAM\n');
fprintf('  Valid iterations : %d\n', K);
fprintf('  Quarters (P)     : %d\n', P);
fprintf('  Pooled obs (N)   : %d\n', N);
fprintf('=======================================================================\n');

% =========================================================================
% Build error matrices [K x P]  (epsilon = method - PAM)
% =========================================================================

% --- TI vs PAM bonds only (Eq. 4.45) ------------------------------------
e_TI_b.M1  = mc.M1_TI(valid,:)  - mc.FX_trans(valid,:);
e_TI_b.M2w = mc.M2w_TI(valid,:) - mc.FX_trans(valid,:);
e_TI_b.M2m = mc.M2m_TI(valid,:) - mc.FX_trans(valid,:);
e_TI_b.M2q = mc.M2q_TI(valid,:) - mc.FX_trans(valid,:);

% --- TI vs PAM bonds+BOM ------------------------------------------------
e_TI_bom.M1  = mc.M1_TI(valid,:)  - mc.FX_trans_BOM(valid,:);
e_TI_bom.M2w = mc.M2w_TI(valid,:) - mc.FX_trans_BOM(valid,:);
e_TI_bom.M2m = mc.M2m_TI(valid,:) - mc.FX_trans_BOM(valid,:);
e_TI_bom.M2q = mc.M2q_TI(valid,:) - mc.FX_trans_BOM(valid,:);

% --- OCI vs PAM translation (Eq. 4.46) ----------------------------------
e_OCI.M1  = mc.M1_OCI(valid,:)  - mc.FX_transl(valid,:);
e_OCI.M2w = mc.M2w_OCI(valid,:) - mc.FX_transl(valid,:);
e_OCI.M2m = mc.M2m_OCI(valid,:) - mc.FX_transl(valid,:);
e_OCI.M2q = mc.M2q_OCI(valid,:) - mc.FX_transl(valid,:);

% --- CC total (trans+transl) vs PAM CC quarterly-avg-rate (Eq. 4.47) ---
Pcc    = min(size(mc.CC_avg_TI, 2), P);
PAM_cc = mc.FX_cc(valid, 1:Pcc);

CC_avg_tot   = mc.CC_avg_TI(valid,1:Pcc)   + mc.CC_avg_OCI(valid,1:Pcc);
CC_close_tot = mc.CC_close_TI(valid,1:Pcc) + mc.CC_close_OCI(valid,1:Pcc);
CC_M1_tot    = mc.M1_CC_TI(valid,1:Pcc)    + mc.M1_CC_OCI(valid,1:Pcc);

e_CC.avg   = CC_avg_tot   - PAM_cc;
e_CC.close = CC_close_tot - PAM_cc;
e_CC.M1    = CC_M1_tot    - PAM_cc;

% =========================================================================
% Print summary tables
% =========================================================================
methods_TI  = {'M1 (daily)',  'M2 weekly', 'M2 monthly', 'M2 quarterly'};
methods_CC  = {'M1 (daily vs LY avg)', 'avg-rate', 'close-rate'};

printTable('TI vs PAM — bonds only (Eq. 4.45)', methods_TI, ...
  {e_TI_b.M1, e_TI_b.M2w, e_TI_b.M2m, e_TI_b.M2q});

printTable('TI vs PAM — bonds+BOM', methods_TI, ...
  {e_TI_bom.M1, e_TI_bom.M2w, e_TI_bom.M2m, e_TI_bom.M2q});

printTable('OCI vs PAM — translation (Eq. 4.46)', methods_TI, ...
  {e_OCI.M1, e_OCI.M2w, e_OCI.M2m, e_OCI.M2q});

printTable('CC vs PAM — quarterly avg rates (Eq. 4.47)', methods_CC, ...
  {e_CC.M1, e_CC.avg, e_CC.close});

% =========================================================================
% KDE plots
% =========================================================================
plotKDE(30, 'TI Errors vs PAM (bonds only)', methods_TI, ...
  {e_TI_b.M1, e_TI_b.M2w, e_TI_b.M2m, e_TI_b.M2q});

plotKDE(31, 'TI Errors vs PAM (bonds+BOM)', methods_TI, ...
  {e_TI_bom.M1, e_TI_bom.M2w, e_TI_bom.M2m, e_TI_bom.M2q});

plotKDE(32, 'OCI Errors vs PAM (translation)', methods_TI, ...
  {e_OCI.M1, e_OCI.M2w, e_OCI.M2m, e_OCI.M2q});

plotKDE(33, 'CC Errors vs PAM (quarterly avg rates)', methods_CC, ...
  {e_CC.M1, e_CC.avg, e_CC.close});

end


%% =========================================================================
function printTable(titleStr, methods, errors)

fprintf('\n--- %s ---\n', titleStr);
fprintf('%-24s %14s %14s %14s %14s %14s\n', ...
  'Method', 'ME (SEK)', 'RMSE (SEK)', 'CI low 95%', 'CI high 95%', 'Std (SEK)');
fprintf('%s\n', repmat('-', 1, 94));

z = 1.96;
for m = 1:length(methods)
  e  = errors{m}(:);
  N  = length(e);
  me   = mean(e);
  rmse = sqrt(mean(e.^2));
  s    = std(e);
  fprintf('%-24s %14s %14s %14s %14s %14s\n', methods{m}, ...
    fmtN(me), fmtN(rmse), ...
    fmtN(me - z*s/sqrt(N)), fmtN(me + z*s/sqrt(N)), fmtN(s));
end
fprintf('%s\n', repmat('-', 1, 94));
end


%% =========================================================================
function plotKDE(figNum, titleStr, methods, errors)

figure(figNum); clf; hold on;
cols = lines(length(methods));

for m = 1:length(methods)
  e = errors{m}(:) / 1e6;   % convert to SEK millions
  [f, x] = ksdensity(e);    % uses Silverman's rule internally
  plot(x, f, 'LineWidth', 1.8, 'Color', cols(m,:), 'DisplayName', methods{m});
end

xline(0, 'k--', 'LineWidth', 1, 'HandleVisibility', 'off');
xlabel('Error (SEK millions)');
ylabel('Density');
title(titleStr);
legend('Location', 'best');
grid on;
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
