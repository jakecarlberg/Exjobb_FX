function m1 = translateMethod1(dm, pnl, bs)
% translateMethod1  Method 1 translation to presentation currency (SEK).
%
%   m1 = translateMethod1(dm, pnl, bs)
%
% Method 1 ("Actual Exchange Rate Method"): each daily EUR increment of the
% P&L is translated at that day's EUR/SEK closing rate and added to the
% running SEK accumulator. Accumulators reset at the start of each quarter.
%
% Outputs:
%   m1.I_R_SEK         [M x 1]   - Revenue in SEK (Method 1, quarterly reset)
%   m1.I_C_SEK         [M x 1]   - COGS in SEK
%   m1.I_F_SEK         [M x 1]   - FX gain/loss in SEK
%   m1.I_N_SEK         [M x 1]   - Net income in SEK
%   m1.dI_R_SEK..dI_N_SEK        - daily increments in SEK
%
% These feed into computeMethod1 to produce the quarterly TI and OCI figures.

M = length(dm.dates);
iCurFunctional   = find(ismember(dm.cName, 'EUR'));
iCurPresentation = find(ismember(dm.cName, 'SEK'));

% EUR -> SEK daily rate
f_EUR_SEK = dm.fx{iCurFunctional, iCurPresentation};

% Daily increments translated at daily rate
dI_R_SEK = pnl.dI_R  .* f_EUR_SEK;
dI_C_SEK = pnl.dI_C  .* f_EUR_SEK;
dI_FU_SEK = pnl.dI_FU .* f_EUR_SEK;
dI_FR_SEK = pnl.dI_FR .* f_EUR_SEK;
dI_F_SEK  = pnl.dI_F  .* f_EUR_SEK;
dI_N_SEK  = dI_R_SEK - dI_C_SEK + dI_F_SEK;

% Quarterly accumulators (reset at quarter boundaries)
I_R_SEK  = accumulateByQuarter(dI_R_SEK,  pnl.quarterStartIdx);
I_C_SEK  = accumulateByQuarter(dI_C_SEK,  pnl.quarterStartIdx);
I_FU_SEK = accumulateByQuarter(dI_FU_SEK, pnl.quarterStartIdx);
I_FR_SEK = accumulateByQuarter(dI_FR_SEK, pnl.quarterStartIdx);
I_F_SEK  = I_FU_SEK + I_FR_SEK;
I_N_SEK  = I_R_SEK - I_C_SEK + I_F_SEK;

m1.I_R_SEK  = I_R_SEK;
m1.I_C_SEK  = I_C_SEK;
m1.I_FU_SEK = I_FU_SEK;
m1.I_FR_SEK = I_FR_SEK;
m1.I_F_SEK  = I_F_SEK;
m1.I_N_SEK  = I_N_SEK;

m1.dI_R_SEK  = dI_R_SEK;
m1.dI_C_SEK  = dI_C_SEK;
m1.dI_FU_SEK = dI_FU_SEK;
m1.dI_FR_SEK = dI_FR_SEK;
m1.dI_F_SEK  = dI_F_SEK;
m1.dI_N_SEK  = dI_N_SEK;

m1.f_EUR_SEK = f_EUR_SEK;

end


function out = accumulateByQuarter(x, qStartIdx)
  out = zeros(size(x));
  nQ = length(qStartIdx);
  for q = 1:nQ
    a = qStartIdx(q);
    if q < nQ, b = qStartIdx(q+1) - 1; else, b = length(x); end
    out(a:b) = cumsum(x(a:b));
  end
end
