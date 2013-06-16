commit d359b76209a4271f346496207932bf0799becc95
Author: Paul van Tilburg <paul@mozcode.nl>
Date:   Sun Jun 16 23:29:33 2013 +0200

    Color invoice list rows based on due status (refs: #b4b365)
    
    What remains is to remove the hardcoding of 30 days.  This should be moved
    to the config and Customer model (and then also be used in the template).
