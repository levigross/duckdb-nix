# The Rust example keeps a durable object in an S3-compatible store over HTTPS. The crate does
# that with ureq and rustls, so this is the one place the program needs TLS to run, and the
# store here is a stand-in with a certificate of its own (s3-standin.py).
#
#   - written to the store by one run of the program, and read back by another that starts
#     with nothing but what the store holds
#   - the same run without the certificate named in AWS_CA_BUNDLE must fail at the handshake,
#     which the store sees, so the check shows the certificate is verified
{ pkgs, program }:

pkgs.runCommand "${program.pname}-check"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.openssl
    ];
  }
  ''
    export HOME=$TMPDIR
    cd $TMPDIR

    # a certificate authority the program is told to trust, and a certificate for the store
    # that it signed: rustls does not accept a self-signed certificate that is a CA as the
    # certificate of a server
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=standin-ca \
      -addext basicConstraints=critical,CA:TRUE -keyout ca.key -out ca.pem 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj /CN=standin -keyout key.pem -out leaf.csr 2>/dev/null
    printf 'subjectAltName=IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n' > leaf.ext
    openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 1 \
      -extfile leaf.ext -out cert.pem 2>/dev/null

    python3 ${./s3-standin.py} 18443 cert.pem key.pem access.log 2>server.err &
    server=$!
    trap 'status=$?; kill $server; if [ $status != 0 ]; then echo "--- access.log"; cat access.log; echo "--- server.err"; cat server.err; fi' EXIT
    for _ in $(seq 100); do
      (exec 3<>/dev/tcp/127.0.0.1/18443) 2>/dev/null && break
      sleep 0.1
    done

    export AWS_ACCESS_KEY_ID=standin AWS_SECRET_ACCESS_KEY=standin AWS_REGION=us-east-1
    url="s3://bucket/objects?endpoint=https://127.0.0.1:18443"

    # without the certificate the store is not trusted: the program fails, and the store sees
    # the client refuse its certificate
    mkdir untrusted
    if TMPDIR=$PWD/untrusted ${program}/bin/chdb-rust-consumer --s3 "$url" write 2>untrusted.err; then
      echo "the program wrote to a store whose certificate it does not trust" >&2
      exit 1
    fi
    sleep 1
    grep -q 'handshake failed' access.log || {
      echo "the store did not see a handshake fail; the program said:" >&2
      cat untrusted.err >&2
      exit 1
    }
    if grep -qE '^(GET|PUT) ' access.log; then
      echo "a request got through without a trusted certificate" >&2
      cat access.log >&2
      exit 1
    fi
    echo "untrusted: $(grep -m1 'handshake failed' access.log)"

    export AWS_CA_BUNDLE=$PWD/ca.pem

    mkdir first second
    TMPDIR=$PWD/first ${program}/bin/chdb-rust-consumer --s3 "$url" write
    TMPDIR=$PWD/second ${program}/bin/chdb-rust-consumer --s3 "$url" read

    puts=$(grep -c '^PUT .* 200 auth=yes' access.log)
    echo "requests the store answered: $(grep -cE '^(GET|PUT) ' access.log), of which $puts were PUTs"
    [ "$puts" -ge 2 ] || { echo "too few writes reached the store" >&2; cat access.log >&2; exit 1; }
    ! grep -q 'auth=no' access.log

    touch $out
  ''
