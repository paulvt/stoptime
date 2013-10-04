commit c1c96a2af0db0f69ee1a7c1f98d7f792bdd988be
Author: Paul van Tilburg <paul@mozcode.nl>
Date:   Fri Oct 4 21:38:42 2013 +0200

    Fix the invoice template to show IBAN/BIC (closes: #688d33)
    
    If IBAN/BIC is set, it is shown instead of the normal account number.
    SEPA solves the problem that needs IBAN/BIC is conditionally shown (which
    is not possible).
