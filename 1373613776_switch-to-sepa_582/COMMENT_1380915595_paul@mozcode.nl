commit 7fcce379035e06aa5d56a39af9b50dc4f74afab3
Author: Paul van Tilburg <paul@mozcode.nl>
Date:   Fri Oct 4 21:38:42 2013 +0200

    Fix the invoice template to show IBAN/BIC (closes: #688d33)
    
    If IBAN/BIC is set, it is shown instead of the normal account number.
    SEPA solves the problem that needs IBAN/BIC is conditionally shown (which
    is not possible).
