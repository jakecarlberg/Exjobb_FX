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

iCurPortfolio = find(ismember(dm.cName, 'SEK'));


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

V = zeros(M,1);
for k=1:Nc
  V = V + VC(:,k).*dm.fx{k, iCurPortfolio};
end

% Portfolio value in EUR (functional currency) - needed for FX benchmarks
iCurFunctional = find(ismember(dm.cName, 'EUR'));
V_EUR = zeros(M,1);
for k=1:Nc
  V_EUR = V_EUR + VC(:,k).*dm.fx{k, iCurFunctional};
end

% Portfolio value in SEK with all FX rates frozen at day 1 (constant-currency basis)
V_SEK_const = zeros(M,1);
for k=1:Nc
  V_SEK_const = V_SEK_const + VC(:,k).*dm.fx{k, iCurPortfolio}(1);
end


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

f_EUR_SEK = dm.fx{iCurFunctional, iCurPortfolio};  % EUR/SEK rate [M x 1]

% Transactional FX (Eq. 4.45): dPf + dPc
%   dPf = FX-rate sensitivity of instruments (FX columns of dVhdPxifMat)
%   dPc = currency-price cross term (dVhdepsf)
iXifCols = 1:Nc^2;  % First Nc^2 xi columns are FX rate risk factors
dFX_trans = [0; full(sum(dVhdPxifMat(2:end, iXifCols), 2))] + dVhdepsf;

% Translation FX (Eq. 4.46): actual SEK change minus EUR change at EUR/SEK
dFX_transl = [0; diff(V) - diff(V_EUR).*f_EUR_SEK(2:end)];

% Constant-currency FX (Eq. 4.47): frozen-FX SEK change minus EUR change at EUR/SEK
dFX_cc = [0; diff(V_SEK_const) - diff(V_EUR).*f_EUR_SEK(2:end)];

dr.xiName    = dc.xiName;
dr.hI        = hI;
dr.hC        = hC;
dr.V         = V;
dr.V_EUR     = V_EUR;
dr.V_SEK_const = V_SEK_const;
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
dr.dFX_trans  = dFX_trans;
dr.dFX_transl = dFX_transl;
dr.dFX_cc     = dFX_cc;
dr.FX_trans   = cumsum(dFX_trans);
dr.FX_transl  = cumsum(dFX_transl);
dr.FX_cc      = cumsum(dFX_cc);


dV = diff(V);
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
  plot(dm.dates, V);
  datetick('x', 'yyyy'); title('Portfolio value (SEK)');

  for i=1:length(VallNames)
    fprintf('%40s %10.2f\n', VallNames{i}, Vall(end,i));
  end

  % -----------------------------------------------------------------------
  % PAM FX Benchmarks (thesis Eqs. 4.45-4.47)
  % -----------------------------------------------------------------------
  figure(6);
  plot(dm.dates, [dr.FX_trans, dr.FX_transl, dr.FX_cc]);
  datetick('x', 'yyyy');
  legend({'Transactional FX (Eq.4.45)', 'Translation FX (Eq.4.46)', 'Constant-currency FX (Eq.4.47)'}, 'Location', 'Best');
  title('PAM FX Benchmarks (cumulative, SEK)');

  fprintf('\n=== PAM FX Benchmarks (cumulative over full period, SEK) ===\n');
  fprintf('  Transactional FX     (Eq.4.45): %12.2f\n', dr.FX_trans(end));
  fprintf('  Translation FX       (Eq.4.46): %12.2f\n', dr.FX_transl(end));
  fprintf('  Constant-currency FX (Eq.4.47): %12.2f\n', dr.FX_cc(end));

end
