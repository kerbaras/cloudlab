# The kerbaras.com zone predates the lab but is now infrastructure of record.
# Records are deliberately NOT managed here: external-dns owns the dynamic
# ones (reconciled from HTTPRoutes in Git), and the static wildcard/host
# records remain hand-managed in the console.
resource "aws_route53_zone" "kerbaras" {
  name = "kerbaras.com"

  lifecycle {
    prevent_destroy = true
  }
}
