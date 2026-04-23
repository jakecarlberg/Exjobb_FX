function [dr] = performanceAttribution(dm, dc, dp, doPlot)
% performanceAttribution  Compute PAM decomposition and FX benchmarks.
%
%   dr = performanceAttribution(dm, dc, dp)         % plots results
%   dr = performanceAttribution(dm, dc, dp, false)  % suppress all output (MC mode)

if nargin < 4 || isempty(doPlot), doPlot = true; end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Performance attribution

M = length(dm.dates);
N = length(dc.assets.assets);
Nc = length(dm.cName);

hI = [dp.hI0 ; repmat(dp.hI0,M-1,1)+cumsum(dp.xBI(2:end,:)-dp.xSI(2:end,:))];
hC = [dp.hC0 ; ones(M-1, Nc)*NaN];

activeAssets = (sum(abs(hI),1)~=0)'; % Only study assets which have non-zero holding

% PAM runs in EUR (functional currency). SEK is the presentation currency.
iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));
iCurPortfolio    = iCurFunctional;   % all decomposition terms in EUR

% Compute currency holdings
for k=1:Nc
  ind = ((dp.IC==k) & activeAssets);
  for i=2:M
    hC(i,k) = hC(i-1,k)*dm.R(i-1,k) + hI(i-1,:)*dp.D{k}(i,:)' + (dp.Pbar(i,ind)-dp.sSI(i,ind))*dp.xSI(i,ind)' - (dp.Pbar(i,ind)+dp.sBI(i,ind))*dp.xBI(i,ind)';
  end
end

VC = ones(M, Nc)*NaN;
for k=1:Nc
  ind = ((dp.IC==k) & activeAssets);
  VC(:,k) = hC(:,k) + sum(hI(:,ind).*dp.Pbar(:,ind),2);
end

% VC1 = ones(M, Nc)*NaN;
% for k=1:Nc
%   ind = ((dp.IC==k) & activeAssets);
%   VC1(1,k) = hC(1,k) + sum(hI(1,ind).*dp.Pbar(1,ind),2);
%   VC1(2:end,k) = hC(1:end-1,k).*dm.R(1:end-1,k) + sum(hI(1:end-1,:).*dp.D{k}(2:end,:),2) + sum((dp.Pbar(2:end,ind)-dp.sSI(2:end,ind)).*dp.xSI(2:end,ind),2) - sum((dp.Pbar(2:end,ind)+dp.sBI(2:end,ind)).*dp.xBI(2:end,ind),2) + sum(hI(2:end,ind).*dp.Pbar(2:end,ind),2);
% end
% 
% VC2 = ones(M, Nc)*NaN;
% for k=1:Nc
%   ind = ((dp.IC==k) & activeAssets);
%   VC2(1,k) = hC(1,k) + sum(hI(1,ind).*dp.Pbar(1,ind),2);
%   VC2(2:end,k) = hC(1:end-1,k).*dm.R(1:end-1,k) + sum(hI(1:end-1,:).*dp.D{k}(2:end,:),2) + sum((dp.Pbar(2:end,ind)-dp.sSI(2:end,ind)).*dp.xSI(2:end,ind),2) - sum((dp.Pbar(2:end,ind)+dp.sBI(2:end,ind)).*dp.xBI(2:end,ind),2) + sum((hI(1:end-1,ind)+dp.xBI(2:end,ind)-dp.xSI(2:end,ind)).*dp.Pbar(2:end,ind),2);
% end
% 
% VC3 = ones(M, Nc)*NaN;
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
%   Ptot = dp.Pbar(:,ind);
%   for j=1:Nc
%     Ptot = Ptot + dp.D{j}(:,ind).*repmat(dm.fx{j,k}, 1, length(ind));
%   end
%   VC3(1,k) = hC(1,k) + hI(1,ind)*dp.Pbar(1,ind)';
%   VC3(2:end,k) = hC(1:end-1,k).*dm.R(1:end-1,k) - sum(dp.sSI(2:end,ind).*dp.xSI(2:end,ind) + dp.sBI(2:end,ind).*dp.xBI(2:end,ind),2) + sum(hI(1:end-1,ind).*Ptot(2:end,:),2);
% end
% 
% fprintf('%d %d %d %d\n', VC(2,5), VC1(2,5), VC2(2,5), VC3(2,5))

if doPlot, figure(1); plot(VC(:,5)); title('VC currency 5'); end

% Portfolio value in EUR (functional currency) — PAM base currency
V_EUR = zeros(M,1);
for k=1:Nc
  V_EUR = V_EUR + VC(:,k).*dm.fx{k, iCurFunctional};
end

% Second PAM run: portfolio currency = SEK (presentation currency), per thesis Eq. 4.46
% Sum currency buckets directly in SEK (mirrors the EUR run above with iCurPresentation)
f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};  % EUR/SEK rate [M x 1]
V_SEK = zeros(M,1);
for k=1:Nc
  V_SEK = V_SEK + VC(:,k).*dm.fx{k, iCurPresentation};
end

% Prior-year same-quarter average FX rates (rolling comparison rates for CC benchmark).
% For each date i, f_comp{k}(i) = mean of dm.fx{k,SEK} over the same calendar quarter
% in the prior year. This makes the frozen rate update every quarter rather than
% being fixed at day 1.
[yr_all, mo_all, da_all] = datevec(dm.dates);
quarter_all = ceil(mo_all / 3);

f_comp = cell(Nc, 1);
for k = 1:Nc
  f_comp{k} = zeros(M, 1);
  for i = 1:M
    mask = (yr_all == yr_all(i)-1) & (quarter_all == quarter_all(i));
    if any(mask)
      f_comp{k}(i) = mean(dm.fx{k, iCurPresentation}(mask));
    else
      f_comp{k}(i) = dm.fx{k, iCurPresentation}(1);  % fallback: earliest available
    end
  end
end
f_EUR_SEK_comp = f_comp{iCurFunctional};  % prior-year quarter average EUR/SEK [M x 1]

% Third PAM run: frozen comparison rates for all currencies → total CC (Eq. 4.47)
V_SEK_const = zeros(M,1);
for k = 1:Nc
  V_SEK_const = V_SEK_const + VC(:,k) .* f_comp{k};
end

% Fourth PAM run: actual transaction rates, frozen EUR/SEK → Translation CC denominator.
% Rate for currency k→SEK = actual k→EUR rate × frozen EUR/SEK comparison rate.
% Mirrors Eq. 4.46 with f_EUR_SEK_comp substituted for actual EUR/SEK.
V_SEK_transl_const = zeros(M,1);
for k = 1:Nc
  V_SEK_transl_const = V_SEK_transl_const + VC(:,k) .* (dm.fx{k, iCurFunctional} .* f_EUR_SEK_comp);
end

% -------------------------------------------------------------------------
% PAM Constant Currency — Last Year Daily Rates
% For each date t, look up the FX rate from the nearest available date
% exactly one year prior (same calendar day, prior year).
% -------------------------------------------------------------------------
target_dns_ly = datenum(yr_all - 1, mo_all, da_all);  % prior-year same-date [M x 1]
idx_ly = zeros(M, 1);
for i = 1:M
  [~, idx_ly(i)] = min(abs(dm.dates - target_dns_ly(i)));
end

f_ly = cell(Nc, 1);
for k = 1:Nc
  f_ly{k} = dm.fx{k, iCurPresentation}(idx_ly);
end
f_EUR_SEK_ly = f_ly{iCurFunctional};  % last-year daily EUR/SEK [M x 1]

% Fifth PAM run: all currencies at last-year daily rates → CC total (LY)
V_SEK_LY = zeros(M, 1);
for k = 1:Nc
  V_SEK_LY = V_SEK_LY + VC(:,k) .* f_ly{k};
end

% Sixth PAM run: actual transaction rates (k→EUR), last-year EUR/SEK → Translation LY denominator.
V_SEK_transl_LY = zeros(M, 1);
for k = 1:Nc
  V_SEK_transl_LY = V_SEK_transl_LY + VC(:,k) .* (dm.fx{k, iCurFunctional} .* f_EUR_SEK_ly);
end

% V is the main portfolio value used for decomposition check — in EUR
V = V_EUR;


epsP = dp.Pbar - dp.P;
depsP = [zeros(1,N) ; epsP(2:end,:)-epsP(1:end-1,:)];

dmPrev = dm; dcPrev = dc;
[dmPrev, dcPrev] = xi2structure(dmPrev, dcPrev, 2);
[PPrev, g, H] = dc.assets.price(dmPrev, dcPrev, activeAssets);

dmSignificant = dm; dcSignificant = dc;
[dmSignificant, dcSignificant] = xi2structure(dmSignificant, dcSignificant, 3);
[PSignificant] = dc.assets.price(dmSignificant, dcSignificant, activeAssets);
% save debugPs PSignificant;

depsI = dp.P - PSignificant;

% i = 666;
% k = 5; % Currency
% fOrg1 = dm.fH{k}(i,:);
% fOrg2 = diff(-log(dm.d{k}(i,:)))/dm.dt;
% figure(1);
% plot([fOrg1 ; fOrg2]');
% 
% fPrev1 = dm.fH{k}(i-1,:);
% fPrev2 = diff(-log(dmPrev.d{k}(i,:)))/dm.dt;
% figure(2);
% plot([fPrev1 ; fPrev2]');
% 
% fSignificant = diff(-log(dmSignificant.d{k}(i,:)))/dm.dt;
% figure(3);
% x = 1:length(fOrg1);
% plot(x, fPrev1, 'b--', x, fOrg1, 'b', x, fSignificant, 'y');


PPrevTot = [ones(size(dp.P(1,:)))*NaN ; dp.P(1:end-1,:)];
for k=1:Nc
  ind = find((dp.IC==k) & activeAssets);
  for j=1:Nc
    PPrevTot(2:end,ind) = PPrevTot(2:end,ind) - dp.D{j}(2:end,ind).*repmat(dm.fx{j,k}(1:end-1), 1, length(ind));
  end
end
dPt = PPrev - PPrevTot;

dPxi = g;
dPq = H;
dPa = dPt;
for i=1:M
  if (i==1)
    dxi = zeros(size(dc.xi(i,:)));
  else
    dxi = dc.xi(i,:) - dc.xi(i-1,:);
  end
  for j=1:N
    if (~activeAssets(j))
      continue;
    end
    [ii,jj,v] = find(dPxi{i,j});
    for k=1:length(ii)
      dPxi{i,j}(ii(k),jj(k)) = v(k)*dxi(ii(k));
    end
    if (nnz(dPxi{i,j}) == 0) % Number of nonzero elements is equal to 0
      dPxi{i,j} = [];
    end
    [ii,jj,v] = find(dPq{i,j});
    for k=1:length(ii)
      dPq{i,j}(ii(k),jj(k)) = 0.5*v(k)*dxi(ii(k))*dxi(jj(k));
    end
    if (nnz(dPq{i,j}) == 0) % Number of nonzero elements is equal to 0
      dPq{i,j} = [];
    end
    dPa(i,j) = dPa(i,j)+sum(dPxi{i,j})+sum(sum(dPq{i,j}));
  end  
end

dP = dp.P - PPrevTot;
depsa = dP - dPa - depsI;
dI = zeros(M, Nc);
for k = 1:Nc
  dI(2:end,k) = hC(1:end-1,k).*(dm.R(1:end-1,k)-1).*dm.fx{k,iCurPortfolio}(1:end-1);
end

dPbar = [ones(size(dp.P(1,:)))*NaN ; dp.Pbar(2:end,:)-PPrevTot(2:end,:)];

depsf = zeros(size(dp.Pbar));
dC = zeros(size(dp.Pbar));
for k=1:Nc
  ind = find((dp.IC==k) & activeAssets);
  depsf(2:end,ind) = dPbar(2:end,ind).*repmat(diff(dm.fx{k, iCurPortfolio}), 1, length(ind));
  dC(:,ind) = (dp.sSI(:,ind).*dp.xSI(:,ind)+dp.sBI(:,ind).*dp.xBI(:,ind)).*repmat(dm.fx{k, iCurPortfolio}, 1, length(ind));
end

dVdI = sum(dI,2);

dVhRdf = zeros(M,1);
for k=1:Nc
  dVhRdf(2:end) = dVhRdf(2:end) + hC(1:end-1,k).*dm.R(1:end-1,k).*diff(dm.fx{k, iCurPortfolio});
end

dVhDdf = zeros(M,1);
for k=1:Nc
  [ii,jj,v] = find(dp.D{k});
  for i=1:length(ii)
    if (ii(i) <= 1)
      continue;
    end
    dVhDdf(ii(i)) = dVhDdf(ii(i)) + hI(ii(i)-1, jj(i))*v(i)*(dm.fx{k, iCurPortfolio}(ii(i))-dm.fx{k, iCurPortfolio}(ii(i)-1));
  end
end

dVdC = - sum(dC,2);

dVhdPtf = zeros(M,1);
dVhdepsaf = zeros(M,1);
dVhdepsIf = zeros(M,1);
dVhdepsPf = zeros(M,1);
for j=1:N
  if (~activeAssets(j))
    continue;
  end
  dVhdPtf(2:end) = dVhdPtf(2:end) + hI(1:end-1, j).*dPt(2:end, j).*dm.fx{dp.IC(j), iCurPortfolio}(1:end-1);
  dVhdepsaf(2:end) = dVhdepsaf(2:end) + hI(1:end-1, j).*depsa(2:end, j).*dm.fx{dp.IC(j), iCurPortfolio}(1:end-1);
  dVhdepsIf(2:end) = dVhdepsIf(2:end) + hI(1:end-1, j).*depsI(2:end, j).*dm.fx{dp.IC(j), iCurPortfolio}(1:end-1);
  dVhdepsPf(2:end) = dVhdepsPf(2:end) + hI(1:end-1, j).*depsP(2:end, j).*dm.fx{dp.IC(j), iCurPortfolio}(1:end-1);
end

% dVhdPxifVec = cell(M,1);
% dVhdPxif = zeros(M,1);
% for i=2:M
%   iiAll = [];
%   jjAll = [];
%   vAll = [];
%   for j=1:N
%     if (hI(i-1, j) == 0)
%       continue;
%     end
%     [ii,jj,v] = find(dPxi{i,j});
%     iiAll = [iiAll ; ii];
%     jjAll = [jjAll ; jj];
%     vAll = [vAll ; hI(i-1, j)*v*dm.fx{dp.IC(j), iCurPortfolio}(i-1)];
%   end
%   dVhdPxifVec{i} = sparse(iiAll, jjAll, vAll);
%   dVhdPxif(i) = sum(dVhdPxifVec{i});
% end
iiAll = [];
jjAll = [];
vAll = [];
for i=2:M
  for j=1:N
    if (hI(i-1, j) == 0)
      continue;
    end
    [ii,jj,v] = find(dPxi{i,j});
    iiAll = [iiAll ; i*ones(size(jj))];
    jjAll = [jjAll ; ii];
    vAll = [vAll ; hI(i-1, j)*v*dm.fx{dp.IC(j), iCurPortfolio}(i-1)];
  end
end
dVhdPxifMat = sparse(iiAll, jjAll, vAll, M, size(dc.xi,2));
dVhdPxif = full(sum(dVhdPxifMat,2));

dVhdPqfMat = cell(M,1);
dVhdPqf = zeros(M,1);
for i=2:M
  iiAll = [];
  jjAll = [];
  vAll = [];
  for j=1:N
    if (~activeAssets(j))
      continue;
    end
    [ii,jj,v] = find(dPq{i,j});
    iiAll = [iiAll ; ii];
    jjAll = [jjAll ; jj];
    vAll = [vAll ; hI(i-1, j)*v*dm.fx{dp.IC(j), iCurPortfolio}(i-1)];
  end
  dVhdPqfMat{i} = sparse(iiAll, jjAll, vAll);
  dVhdPqf(i) = sum(sum(dVhdPqfMat{i}));
end

dVhPdf = zeros(M,Nc);
for k=1:Nc
  ind = ((dp.IC==k) & activeAssets);
  dVhPdf(2:end, k) = sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*diff(dm.fx{k, iCurPortfolio});
end
dVhPtotdf = sum(dVhPdf,2);

dVhdepsf = zeros(M,1);
dVhdepsf(2:end) = sum(hI(1:end-1,:).*depsf(2:end,:),2);

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PAM FX Benchmarks (thesis Eqs. 4.45-4.47)
% All benchmarks expressed in SEK for comparison with Method 1 and Method 2.

% Transactional FX (Eq. 4.45): in EUR (PAM runs in EUR)
%   dPf = FX-rate sensitivity of instruments (FX columns of dVhdPxifMat)
%   dPc = currency-price cross term (dVhdepsf)
%   These capture transaction->EUR rate moves only (EUR is portfolio currency,
%   so EUR/SEK does not appear as a risk factor here)
iXifCols = 1:Nc^2;  % First Nc^2 xi columns are FX rate risk factors
dFX_trans_EUR = [0; full(sum(dVhdPxifMat(2:end, iXifCols), 2))] + dVhdepsf;

% Translate transactional FX to SEK at daily EUR/SEK rate (Eq. 4.45 in SEK)
dFX_trans = dFX_trans_EUR .* f_EUR_SEK;

% Translation FX (Eq. 4.46): daily change from SEK run minus EUR run converted to SEK
% V_SEK comes from the second PAM run (c_p = SEK), isolating EUR/SEK movements
dFX_transl = [0; diff(V_SEK) - diff(V_EUR).*f_EUR_SEK(2:end)];

% Constant-currency FX (Eq. 4.47): frozen-rate SEK change minus EUR change at EUR/SEK
dFX_cc = [0; diff(V_SEK_const) - diff(V_EUR).*f_EUR_SEK(2:end)];

% Decompose CC using the fourth PAM run (mirrors Eq. 4.46 / 4.47 structure):
%   Translation CC: fourth run (actual transaction, frozen EUR/SEK) vs EUR run
%   Transaction CC: residual = total CC minus translation CC
dFX_cc_total  = dFX_cc;
dFX_transl_CC = [0; diff(V_SEK_transl_const) - diff(V_EUR) .* f_EUR_SEK(2:end)];
dFX_trans_CC  = dFX_cc_total - dFX_transl_CC;

% PAM Constant Currency — Last Year Daily Rates decomposition:
%   Total LY CC: fifth run (all LY rates) vs EUR run at actual EUR/SEK
%   Translation LY CC: sixth run (actual trans, LY EUR/SEK) vs EUR run
%   Transaction LY CC: residual
dFX_cc_LY_total  = [0; diff(V_SEK_LY)       - diff(V_EUR) .* f_EUR_SEK(2:end)];
dFX_transl_CC_LY = [0; diff(V_SEK_transl_LY) - diff(V_EUR) .* f_EUR_SEK(2:end)];
dFX_trans_CC_LY  = dFX_cc_LY_total - dFX_transl_CC_LY;


dr.xiName    = dc.xiName;
dr.hI        = hI;
dr.hC        = hC;
dr.V         = V_SEK;        % presentation currency (SEK) for reporting
dr.V_EUR     = V_EUR;        % functional currency (EUR) — PAM base
dr.V_SEK     = V_SEK;
dr.V_SEK_const        = V_SEK_const;
dr.V_SEK_transl_const = V_SEK_transl_const;
dr.V_SEK_LY           = V_SEK_LY;
dr.V_SEK_transl_LY    = V_SEK_transl_LY;
dr.dFX_trans_EUR = dFX_trans_EUR;
dr.dVdI      = dVdI;
dr.dVhRdf    = dVhRdf;
dr.dVhDdf    = dVhDdf;
dr.dVdC      = dVdC;
dr.dVhdPtf   = dVhdPtf;
dr.dVhdPxifMat = dVhdPxifMat;
dr.dVhdPxif  = dVhdPxif;
dr.dVhdPqf   = dVhdPqf;
dr.dVhdepsaf = dVhdepsaf;
dr.dVhdepsIf = dVhdepsIf;
dr.dVhdepsPf = dVhdepsPf;
dr.dVhPtotdf = dVhPtotdf;
dr.dVhdepsf  = dVhdepsf;
dr.dFX_trans      = dFX_trans;
dr.dFX_transl     = dFX_transl;
dr.dFX_cc         = dFX_cc;
dr.FX_trans       = cumsum(dFX_trans);
dr.FX_transl      = cumsum(dFX_transl);
dr.FX_cc          = cumsum(dFX_cc);
dr.f_EUR_SEK_comp  = f_EUR_SEK_comp;
dr.dFX_trans_CC   = dFX_trans_CC;
dr.dFX_transl_CC  = dFX_transl_CC;
dr.dFX_cc_total   = dFX_cc_total;
dr.FX_trans_CC    = cumsum(dFX_trans_CC);
dr.FX_transl_CC   = cumsum(dFX_transl_CC);
dr.FX_cc_total    = cumsum(dFX_cc_total);
dr.dFX_trans_CC_LY   = dFX_trans_CC_LY;
dr.dFX_transl_CC_LY  = dFX_transl_CC_LY;
dr.dFX_cc_LY_total   = dFX_cc_LY_total;
dr.FX_trans_CC_LY    = cumsum(dFX_trans_CC_LY);
dr.FX_transl_CC_LY   = cumsum(dFX_transl_CC_LY);
dr.FX_cc_LY_total    = cumsum(dFX_cc_LY_total);

% Sanity check: trans_CC + transl_CC must equal total CC
assert(max(abs(dFX_trans_CC + dFX_transl_CC - dFX_cc_total)) < 1e-6, ...
  'CC decomposition does not sum to total');

% Sanity check: LY trans_CC + LY transl_CC must equal LY total CC
assert(max(abs(dFX_trans_CC_LY + dFX_transl_CC_LY - dFX_cc_LY_total)) < 1e-6, ...
  'CC LY decomposition does not sum to total');

% Quarterly aggregation of CC components (same periodDates logic as runMC.m)
% Produces per-quarter totals for comparison against Method 1, 2, and 2b.
periodDates = makeQuarterDates(dm.dates(1), dm.dates(end));
nPeriods    = length(periodDates) - 1;
dr.FX_trans_CC_quarterly  = zeros(nPeriods, 1);
dr.FX_transl_CC_quarterly = zeros(nPeriods, 1);
dr.FX_cc_total_quarterly  = zeros(nPeriods, 1);
dr.FX_trans_CC_LY_quarterly  = zeros(nPeriods, 1);
dr.FX_transl_CC_LY_quarterly = zeros(nPeriods, 1);
dr.FX_cc_LY_total_quarterly  = zeros(nPeriods, 1);
for p = 1:nPeriods
  idx = find(dm.dates > periodDates(p) & dm.dates <= periodDates(p+1));
  dr.FX_trans_CC_quarterly(p)  = sum(dFX_trans_CC(idx));
  dr.FX_transl_CC_quarterly(p) = sum(dFX_transl_CC(idx));
  dr.FX_cc_total_quarterly(p)  = sum(dFX_cc_total(idx));
  dr.FX_trans_CC_LY_quarterly(p)  = sum(dFX_trans_CC_LY(idx));
  dr.FX_transl_CC_LY_quarterly(p) = sum(dFX_transl_CC_LY(idx));
  dr.FX_cc_LY_total_quarterly(p)  = sum(dFX_cc_LY_total(idx));
end
dr.periodDates = periodDates;

% Decomposition check: residual should be ~zero (all in EUR)
dV = diff(V_EUR);
dVd = dVdI + dVhRdf + dVhDdf + dVdC + dVhdPtf + dVhdPxif + dVhdPqf + dVhdepsaf + dVhdepsIf + dVhdepsPf + dVhPtotdf + dVhdepsf;
dVd = dVd(2:end);

figure(1);
plot([dV-dVd])
% plot(cumsum([dV dV2],1))



% dV4 = dVdI + dVhRdf + dVhDdf + dVdC;
% dV4 = dV4(2:end);
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
%   dV4 = dV4 + sum(hI(1:end-1,ind).*dp.Pbar(2:end,ind),2).*dm.fx{k, iCurPortfolio}(2:end) - sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*dm.fx{k, iCurPortfolio}(1:end-1);
% end
% 
% % Use delta Pbar to rewrite the change in portfolio value
% dV4a = dVdI + dVhRdf + dVhDdf + dVdC;
% dV4a = dV4a(2:end);
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
%   dV4a = dV4a + sum(hI(1:end-1,ind).*dp.Pbar(2:end,ind),2).*dm.fx{k, iCurPortfolio}(2:end);
%   dV4a = dV4a - sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*dm.fx{k, iCurPortfolio}(1:end-1);
% end
% 
% % Use delta Pbar to rewrite the change in portfolio value
% dV4b = dVdI + dVhRdf + dVhDdf + dVdC;
% dV4b = dV4b(2:end);
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
%   dV4b = dV4b + sum(hI(1:end-1,ind).*dp.Pbar(2:end,ind),2).*(dm.fx{k, iCurPortfolio}(1:end-1) + diff(dm.fx{k, iCurPortfolio}));
%   dV4b = dV4b - sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*dm.fx{k, iCurPortfolio}(1:end-1);
% end
% 
% % Use delta Pbar to rewrite the change in portfolio value
% dV4c = dVdI + dVhRdf + dVhDdf + dVdC;
% dV4c = dV4c(2:end);
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
% %   tmp = PPrevTot(2:end,ind) + dPbar(2:end,ind) - dp.Pbar(2:end,ind);
% %   fprintf('%d %d\n', k, sum(sum(abs(tmp))));
%   dV4c = dV4c + sum(hI(1:end-1,ind).*(PPrevTot(2:end,ind) + dPbar(2:end,ind)),2).*(dm.fx{k, iCurPortfolio}(1:end-1) + diff(dm.fx{k, iCurPortfolio}));
%   dV4c = dV4c - sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*dm.fx{k, iCurPortfolio}(1:end-1);
% end
% 
% 
% dV5 = dVdI + dVhRdf + dVhDdf + dVdC;
% dV5 = dV5(2:end);
% for k=1:Nc
%   ind = find((dp.IC==k) & activeAssets);
%   lhs = (PPrevTot(2:end,ind) + dPbar(2:end,ind)).*repmat((dm.fx{k, iCurPortfolio}(1:end-1) + diff(dm.fx{k, iCurPortfolio})), 1, length(ind)) - PPrevTot(2:end,ind).*repmat(dm.fx{k, iCurPortfolio}(1:end-1), 1, length(ind));
%   rhs = dPbar(2:end,ind).*repmat(dm.fx{k, iCurPortfolio}(1:end-1), 1, length(ind)) + PPrevTot(2:end,ind).*repmat(diff(dm.fx{k, iCurPortfolio}), 1, length(ind)) + depsf(2:end,ind);
%   fprintf('%d %d\n', k, sum(sum(abs(lhs-rhs))));
%   dV5 = dV5 + sum(hI(1:end-1,ind).*dPbar(2:end,ind),2).*dm.fx{k, iCurPortfolio}(1:end-1);
%   dV5 = dV5 + sum(hI(1:end-1,ind).*PPrevTot(2:end,ind),2).*diff(dm.fx{k, iCurPortfolio});
%   dV5 = dV5 + sum(hI(1:end-1,ind).*depsf(2:end,ind),2);
% end


if doPlot
  dVall = [dVdI dVhRdf dVhDdf dVdC dVhdPtf dVhdPxif dVhdPqf dVhdepsaf dVhdepsIf dVhdepsPf dVhPtotdf dVhdepsf];
  dVall = dVall(2:end,:);
  [~, ind] = sort(max(abs(dVall),[],1), 'descend');
  Vall = cumsum(dVall,1);
  nPlot = 7;
  VallNames = {'dVdI' 'dVhRdf' 'dVhDdf' 'Procurement/Sales gain (dVdC)' 'dVhdPtf' 'Linear risk factors (dVhdPxif)' 'Quadratic risk factors (dVhdPqf)' 'dVhdepsaf' 'dVhdepsIf' 'dVhdepsPf' 'dVhPtotdf' 'dVhdepsf'};
  figure(2);
  plot(Vall(:,ind(1:nPlot)));
  legend(VallNames(ind(1:nPlot)), 'Location', 'Best');
  title('PAM decomposition (top 7 terms)');

  figure(3);
  [~, ind] = sort(max(abs(dVhdPxifMat),[],1), 'descend');
  nPlot = 4;
  plot(cumsum(dVhdPxifMat(:,ind(1:nPlot))));
  legend(dc.xiName(ind(1:nPlot)), 'Location', 'Best');
  title('Top FX/IR risk factors (cumulative)');

  figure(4);
  ind = 8:10;
  plot(Vall(:,ind));
  legend(VallNames(ind), 'Location', 'Best');
  title('Slippage terms');

  figure(5);
  plot(dm.dates, V_EUR);
  datetick('x', 'yyyy'); title('Portfolio value (EUR, functional currency)');

  figure(6);
  plot(dm.dates, V_SEK);
  datetick('x', 'yyyy'); title('Portfolio value (SEK, presentation currency)');

  for i=1:length(VallNames)
    fprintf('%40s %18s\n', VallNames{i}, fmtNum(Vall(end,i), 2));
  end

  % -----------------------------------------------------------------------
  % PAM FX Benchmarks (thesis Eqs. 4.45-4.47) — all in SEK
  % -----------------------------------------------------------------------
  figure(7);
  plot(dm.dates, [dr.FX_trans, dr.FX_transl, dr.FX_cc]);
  datetick('x', 'yyyy');
  legend({'Transactional FX (Eq.4.45)', 'Translation FX (Eq.4.46)', 'Constant-currency FX (Eq.4.47)'}, 'Location', 'Best');
  title('PAM FX Benchmarks (cumulative, SEK)');

  figure(8);
  plot(dm.dates, [dr.FX_trans_CC, dr.FX_transl_CC, dr.FX_cc_total]);
  datetick('x', 'yyyy');
  legend({'CC Transaction component', 'CC Translation component', 'CC Total (trans+transl)'}, 'Location', 'Best');
  title('PAM CC Decomposition — Quarterly Avg Rates (cumulative, SEK)');

  figure(9);
  plot(dm.dates, [dr.FX_trans_CC_LY, dr.FX_transl_CC_LY, dr.FX_cc_LY_total]);
  datetick('x', 'yyyy');
  legend({'CC Transaction component (LY)', 'CC Translation component (LY)', 'CC Total (LY)'}, 'Location', 'Best');
  title('PAM Constant Currency — Last Year Daily Rates (cumulative, SEK)');

  fprintf('\n=== PAM FX Benchmarks (cumulative over full period, SEK) ===\n');
  fprintf('  Transactional FX     (Eq.4.45): %20s\n', fmtNum(dr.FX_trans(end), 2));
  fprintf('  Translation FX       (Eq.4.46): %20s\n', fmtNum(dr.FX_transl(end), 2));
  fprintf('  Constant-currency FX (Eq.4.47): %20s\n', fmtNum(dr.FX_cc(end), 2));
  fprintf('\n=== PAM CC Decomposition — Quarterly Avg Rates (cumulative, SEK) ===\n');
  fprintf('  CC Transaction component:       %20s\n', fmtNum(dr.FX_trans_CC(end), 2));
  fprintf('  CC Translation component:       %20s\n', fmtNum(dr.FX_transl_CC(end), 2));
  fprintf('  CC Total (trans + transl):      %20s\n', fmtNum(dr.FX_cc_total(end), 2));
  fprintf('\n=== PAM Constant Currency — Last Year Daily Rates (cumulative, SEK) ===\n');
  fprintf('  CC Transaction component (LY):  %20s\n', fmtNum(dr.FX_trans_CC_LY(end), 2));
  fprintf('  CC Translation component (LY):  %20s\n', fmtNum(dr.FX_transl_CC_LY(end), 2));
  fprintf('  CC Total (LY):                  %20s\n', fmtNum(dr.FX_cc_LY_total(end), 2));

end
