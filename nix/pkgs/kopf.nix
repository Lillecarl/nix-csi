{
  kopf,
  certbuilder,
}:
kopf.overrideAttrs (prev: {
  propagatedBuildInputs = (prev.propagatedBuildInputs or [ ]) ++ [ certbuilder ];
  doCheck = false;
  doInstallCheck = false;
})
