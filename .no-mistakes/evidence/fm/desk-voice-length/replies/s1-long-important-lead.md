Captain, the payments migration finished and every service is green again. The one thing to know is that refunds were paused for about twenty minutes during the cutover. Three customers saw a failed refund and I have retried all three successfully. The billing dashboard now reads from the new database. Nothing is waiting on you. Tomorrow I will remove the old tables once the nightly backup confirms.

Detail:
- migration ran 14:02 to 14:31
- refunds retried: r_1928, r_1931, r_1940
- PR https://github.com/example/repo/pull/412
