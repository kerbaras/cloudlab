variable "domain" {
  type        = string
  description = "(optional) fqdn for the lab"
  default     = "kerbaras.com"
}

variable "contact" {
  type        = string
  description = "(optional) email address for the contact of the lab"
}

variable "hosted_zone_id" {
  type        = string
  description = "(optional) hosted zone id for the lab"
}
