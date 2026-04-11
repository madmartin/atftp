# ATFTP Readme

## Original README

By Jean-Pierre Lefebvre <helix@step.polymtl.ca> / August 20th, 2000

**atftp** stands for **Advanced Trivial File Transfer Protocol**

 It is called "advanced", by contrast to others TFTP servers, for two reasons.

Firstly, it is intended to be fully compliant with all related RFCs. This include RFC1350, RFC2090, RFC2347, RFC2348, RFC2349 and RFC7440.

To my knowledge, there is no TFTP server currently available in the public domain that fulfils this requirement.

Secondly, atftp is intended for serving boot files to large clusters. It is multi-threaded and support multicast (RFC2090 and PXE), allowing faster boot of hundreds of machine simultaneously.

I started writing the atftp server after trying to boot Debian from the LAN using pxelinux (distributed with syslinux). Since pxelinux needs support for the "tsize" option defined in RFC2349, I looked for different TFTP servers but found none that fulfilled my needs.

With atftp, I have successfully used pxelinux and dhcpd to boot from the LAN. Unfortunately, new development will slow down since I do it on my spare time and atftp now does what I need.  However, atftp is actively maintained.

Comments, bug reports and patches are welcome.

Great thanks to my brother Remi who works on the client and server implementation and the debian packaging.

## Project Home

is [SourceForge](https://sourceforge.net/projects/atftp/)
with a mirror on [GitHub](https://github.com/madmartin/atftp/)

---

## Multicast TFTP

Atftp supports multicast transfer. This feature allows the server to send a file to many clients at once.

There are two ways of doing multicast TFTP.
One is documented in RFC2090 and the other is known as MTFTP and documented in Intel's PXE specification.

Atftp supports both protocols.

### RFC2090

Multicast using RFC2090 is very similar to any other TFTP transfer. The read request sent by the client contains an option to inform the server to
use multicast. The server will send configuration information (IP and port) through the option acknowledge mechanism. The initial read
request is done at the same port as without multicast (port 69 in most configuration). Data transfer is done at IP and port chosen by the server.

When more clients connect to the server, atftpd tries to find a thread currently sending the same file. If it exists, this thread will take
care of the new client. If not, a new thread is started for that new client. It is possible to send many different files to many clients
when using multicast. Each file transfer uses a unique IP and port.

### MTFTP

The PXE specification uses a completely different (and incompatible with RFC2090) way of doing things. Basically, the TFTP
request is sent at a different port than a normal TFTP request. Various options like IP address, port and timeout value are fetched by the client
from a DHCP server. Server configuration is done with command line arguments and a configuration file. It is much less flexible than
RFC2090 since configuration of the DHCP server must match the configuration of atftpd. See the file mtftp.conf as an example. Most boot ROMs use this
method for multicast transfer since it is part of the PXE specification (ftp://download.intel.com/labs/manage/wfm/download/pxespec.pdf).

**Note:** mtftp support starting in atftp 0.7 is experimental.

---

## File name mangling with PCRE in atftpd

Here is an attempt at using PCRE (Perl Compatible Regular Expressions) with a TFTP server. The first question on your mind is most likely "Why in
blazes would anyone want to use a regular expression with a TFTP server?"
Imagine you have a network of machines that all download an identical config file, but each machine requests its file as `<serialno>.conf` where
`<serialno>` is the serial number of the machine. This setup is useful when you wish each machine to have individual configs. When you wish to have
identical configurations on each box this is annoying. The solution is to map all requested files ending in `.conf` to one `master.conf` file via a
regex. The exact expression I use is

```text
^\w*\.conf$     master.conf
```

The left hand side is the expression to match, the right hand side is the substitution. This is equivalent to perl's `s///` statement. One or more of these
expressions can be stored in a file (one per line) and feed to atftpd via a `--pcre <filename>` switch on the command line.

Example:

```bash
./atftpd --daemon --pcre ./test/pcre_pattern.txt /tftpboot/
```

Also included is a test program using the `--pcre-test <filename>` option. You can interactively (or via redirection) feed file name to atftpd and look at
the substitution to verify your rules.

Example:

```bash
./atftpd --pcre-test ./test/pcre_pattern.txt
```

---

## Authors

Jean-Pierre Lefebvre <helix@step.polymtl.ca>

Remi Lefebvre <remi@debian.org>

## Contributors

may be incomplete

Jeff Miller <jeff.miller@transact.com.au>

Leif Lindholm <leif.lindholm@i3micro.com>

Jens Schmidt <Jens.A.Schmidt@dxd.ericsson.se>

Svend Odgaard <Svend.Odgaard@dxd.ericsson.se>

Joshua Aune <luken@linuxnetworx.com>

Mario Lorenz <Mario.Lorenz@km3.de>

Allen Reese <areese@lnxi.com>

Thayne Harbaugh <tharbaugh@lnxi.com>

Thomas Anders <thomas.anders@blue-cable.de>

Michał Rzechonek <m.rzechonek@kelvatek.com>

Jeff <jeffm@ghostgun.com>

Florian Fainelli <f.fainelli@gmail.com>

Denis Andzakovic <denis.andzakovic@pulsesecurity.co.nz>

Rosen Penev <rosenp@gmail.com>

Peter Kaestle <peter.kaestle@nokia.com>

Grant Edwards

Ryan Barnett <ryan.barnett@rockwellcollins.com>

Peter Seiderer <ps.report@gmx.net>

Simon Rettberg <simon.rettberg@rz.uni-freiburg.de>

Andreas B. Mundt <andi@debian.org>

Florian Eckert <fe@dev.tdt.de>

Florian Schmaus <flo@geekplace.eu>

Kasparek Tomas <kasparek@fit.vutbr.cz>

Aurelien Jarno <aurel32@debian.org>

James Cowgill <jcowgill@debian.org>
