// From Ben Goodrich https://discourse.datamethods.org/t/fully-sequential-bayesian-clinical-trial-design-for-in-hospital-treatment-of-covid-19
// Based on section 13.3.1 of http://hbiostat.org/doc/rms.pdf
functions { // can check these match rms::orm via rstan::expose_stan_functions
  // pointwise log-likelihood contributions
  vector pw_log_lik(vector alpha, vector beta, real rho, row_vector[] X, int[] y, 
                    int[] cluster, int[] time, vector gamma, vector eps) {
    int N = size(X);
    vector[N] out;
    int k = max(y); // assumes all possible categories are observed
		int Nt = max(time);
		vector[Nt] eps_n;
    for (n in 1:N) {
			int cln = cluster[n];
			eps_n[1] = gamma[cln];
			eps_n[2 : Nt] = rho * eps_n[1 : (Nt - 1)] + eps[cln][2 : Nt];
			real eta = X[n] * beta + eps_n[time[n]];
      int y_n = y[n];
      if (y_n == 1) out[n] = log1m_exp(-log1p_exp(-alpha[1] - eta));
      else if (y_n == k) out[n] = -log1p_exp(-alpha[k - 1]  - eta);
      else out[n] = log_diff_exp(-log1p_exp(-alpha[y_n - 1] - eta),
                                 -log1p_exp(-alpha[y_n]     - eta));
    }
    return out;
  }
  
  // Pr(y == j)
  matrix Pr(vector alpha, vector beta, real rho, row_vector[] X, int[] y, 
            int[] cluster, int[] time, vector gamma, vector[] eps) {
    int N = size(X);
    int k = max(y); // assumes all possible categories are observed
		int Nt = max(time);
		vector[Nt] eps_n;
    matrix[N, k] out;
    for (n in 1:N) {
		int cln = cluster[n];
		eps_n[1] = gamma[cln];
		eps_n[2 : Nt] = rho * eps_n[1 : (Nt - 1)] + eps[cln, 2 : Nt];
      real eta = X[n] * beta + eps_n[time[n]];
      out[n, 1] = log1m_exp(-log1p_exp(-alpha[1] - eta));
      out[n, k] = -log1p_exp(-alpha[k - 1]  - eta);
      for (y_n in 2:(k - 1))
        out[n, y_n] = log_diff_exp(-log1p_exp(-alpha[y_n - 1] - eta),
                                   -log1p_exp(-alpha[y_n]     - eta));
    }
    return exp(out);
  }
}
data {
  int<lower = 1> N;   // number of observations
  int<lower = 1> Nc;  // number of clusters
	int<lower = 1> Nt;  // number of time points (= maximum integer time)
  int<lower = 1> p;   // number of predictors
  matrix[N, p] X;     // matrix of CENTERED predictors WITH TREATMENT LAST
  int<lower = 2> k;   // number of outcome categories (7)
  int<lower = 1, upper = k> y[N]; // outcome on 1 ... k
  int<lower = 1, upper = Nc> cluster[N];  // cluster IDs
	int<lower = 1, upper = Nt> time[N];   // measurement times (integers)
  
  // prior standard deviations
  vector<lower = 0>[p] sds;
  real<lower = 0> rate;
	real<lower = 0> ratew;    // for within-subject white noise sigmaw
	real<lower = -1, upper = 1> rho;        // AR(1) correlation
}

transformed data {
  matrix[N, p] Q_ast = qr_thin_Q(X);
  matrix[p, p] R_ast = qr_thin_R(X);
  real corner = R_ast[p, p];
  matrix[p, p] R_ast_inverse = inverse(R_ast);
  row_vector[p] Q_list[N];

  // renormalize so that R_ast[p, p] = 1
  // THIS IMPLIES THE TREATMENT EFFECT IS UNAFFECTED BY THE ROTATION
  Q_ast *= corner;
  R_ast /= corner;
  R_ast_inverse *= corner;
  
  for (n in 1:N) Q_list[n] = Q_ast[n, ];
}

parameters {
  vector[p] theta; // coefficients on Q_ast
  simplex[k] pi;  // category probabilities for a person w/ average predictors
  vector[Nc] gamma_raw;  // unscaled random effects
  real<lower = 0> sigmag;   // SD of random effects
	vector[Nc] eps_raw[Nt];    // unscaled within-subject noise
	real<lower = 0> sigmaw;   // SD of within-subject noise
}

transformed parameters {
  vector[k - 1] alpha;                               // intercepts
  vector[Nc] gamma = sigmag * gamma_raw;             // scaled random effects
	vector[Nc] eps[Nt]  = sigmaw * eps_raw;            // scaled within subj
  vector[N] log_lik;                                 // log-likelihood pieces
  for (j in 2:k) alpha[j - 1] = logit(sum(pi[j:k])); // predictors are CENTERED
  log_lik = pw_log_lik(alpha, theta, rho, Q_list, y, cluster, gamma, eps);
}

model {
  gamma_raw ~ std_normal(); // implies: gamma ~ normal(0, sigmag)
	eps_raw ~ std_normal();   // implies: eps   ~ normal(0, sigmaw)
  sigmag ~ exponential(rate);
	sigmaw ~ exponential(ratew);
  target += log_lik;
  target += normal_lpdf(theta | 0, sds);
  // implicit: pi ~ dirichlet(ones)
}

generated quantities {
  vector[p] beta = R_ast_inverse * theta;            // coefficients on X
  vector[p] OR = exp(beta);
}
