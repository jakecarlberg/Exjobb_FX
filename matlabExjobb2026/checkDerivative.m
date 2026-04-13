function checkDerivative(dm, dc, pa)

[p, g, H] = pa.price(dm, dc);

nXi = size(dc.xi,2);
ind = false(nXi,1);
for i=1:nXi
  dm2 = dm; dc2 = dc;
  dc2.xi(:,i) = NaN;
  [dm2, dc2] = xi2structure(dm2, dc2);
  [p2] = pa.price(dm2, dc2);
  ind(i) = (sum(abs(p-p2)) == 0);
end
ind = find(~ind);

M = length(dm.dates);


eps = 1E-4;
epsScale = 1E4;

% dPdxi
gMatNum = zeros(M, nXi);
HTenNum = zeros(M, nXi, nXi);
for ii=1:length(ind)
  i = ind(ii);
  if (i >= dc.xiI2xiInd{1}(1) && i <= dc.xiI2xiInd{end}(end))
    epsi = eps*epsScale;
  else
    epsi = eps;
  end
  dm2 = dm; dc2 = dc;
  dc2.xi(:,i) = dc.xi(:,i)+epsi;
  [dm2, dc2] = xi2structure(dm2, dc2);
  [pp] = pa.price(dm2, dc2);

  dm2 = dm; dc2 = dc;
  dc2.xi(:,i) = dc.xi(:,i)-epsi;
  [dm2, dc2] = xi2structure(dm2, dc2);
  [pm] = pa.price(dm2, dc2);
  
  gMatNum(:,i) = (pp-pm)/(2*epsi);

  for jj=1:length(ind)
    j = ind(jj);
    if (j >= dc.xiI2xiInd{1}(1) && j <= dc.xiI2xiInd{end}(end))
      epsj = eps*epsScale;
    else
      epsj = eps;
    end
    if (i == j)
      HTenNum(:,i,j) = (pp-2*p+pm)/epsi^2;
    else
      dm2 = dm; dc2 = dc;
      dc2.xi(:,i) = dc.xi(:,i)+epsi;
      dc2.xi(:,j) = dc.xi(:,j)+epsj;
      [dm2, dc2] = xi2structure(dm2, dc2);
      [ppp] = pa.price(dm2, dc2);

      dm2 = dm; dc2 = dc;
      dc2.xi(:,i) = dc.xi(:,i)+epsi;
      dc2.xi(:,j) = dc.xi(:,j)-epsj;
      [dm2, dc2] = xi2structure(dm2, dc2);
      [ppm] = pa.price(dm2, dc2);

      dm2 = dm; dc2 = dc;
      dc2.xi(:,i) = dc.xi(:,i)-epsi;
      dc2.xi(:,j) = dc.xi(:,j)+epsj;
      [dm2, dc2] = xi2structure(dm2, dc2);
      [pmp] = pa.price(dm2, dc2);

      dm2 = dm; dc2 = dc;
      dc2.xi(:,i) = dc.xi(:,i)-epsi;
      dc2.xi(:,j) = dc.xi(:,j)-epsj;
      [dm2, dc2] = xi2structure(dm2, dc2);
      [pmm] = pa.price(dm2, dc2);
      
      HTenNum(:,i,j) = (ppp - ppm - pmp + pmm)/(4*epsi*epsj);
    end
  end
end

gNum = cell(M, 1);
HNum = cell(M, 1);
for i=1:M
  vec = gMatNum(i,:)';
  if (sum(abs(vec))>0)
    gNum{i} = sparse(vec);
  end
  mat = squeeze(HTenNum(i,:,:));
  if (sum(sum(abs(mat)))>0)
    HNum{i} = sparse(mat);
  end
end

for i=1:M
  if (size(gNum{i},1) > 0)
    fprintf('%3d %15d', i, full(sum(g{i}-gNum{i})))
  end
  if (size(HNum{i},1) > 0)
    fprintf(' %15d', full(sum(sum(H{i}-HNum{i}))))
  end
  if (size(gNum{i},1) > 0)
    fprintf('\n')
  end
end
