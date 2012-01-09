commit 016cb0b21d4eff4b92c25775d01ab05c7457f57a
Author: Paul van Tilburg <paul@mozcode.nl>
Date:   Mon Jan 9 15:48:20 2012 +0100

    Added company info revisioning in the models (refs: #ba1a26)
    
    * Extended CompanyInfo with an "original" association with the previous
      revision (in case revisions can be removed in the future).
    * Created a belongs_to relation of Invoice with CompanyInfo and an
      has_many reverse relation.
