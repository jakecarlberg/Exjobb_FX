problem forwardRatesLS;

param p;                 # Weight for price error
param dt;                # Discretization of forward rates
param n;                 # The number of forward rates
param m;                 # The number of continuously compounded spot rates

param M{1..m};           # The maturity for each continuously compounded spot rates
param r{1..m};	         # The continuously compounded spot rates
param cb{0..n-2};        # Weight for second order derivative penalty

var f{0..n-1};           # Forward rates
var z{1..m};             # Price error

minimize obj: sum {t in 1..n-2} cb[t]*((f[t+1]+f[t-1]-2*f[t])/dt^2)^2*dt + sum {i in 1..m} p * z[i]^2;

subject to consistent{i in 1..m}:
sum{t in 0..M[i]-1} f[t]*dt + z[i]*M[i]*dt = r[i]*M[i]*dt;
