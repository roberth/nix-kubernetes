{ config, lib, k8s, pkgs, ... }:

with lib;

let
  fixJSON = content: replaceStrings ["\\u"] ["u"] content;

  fetchSpecs = url: sha256:
    builtins.fromJSON (fixJSON (builtins.readFile (pkgs.fetchurl { inherit url sha256; })));

  hasTypeMapping = def:
    hasAttr "type" def &&
    elem def.type ["string" "integer" "boolean" "object"];

  mapType = def:
    if def.type == "string" then
      if hasAttr "format" def && def.format == "int-or-string"
      then types.either types.int types.str
      else types.str
    else if def.type == "integer" then types.int
    else if def.type == "boolean" then types.bool
    else if def.type == "object" then types.attrs
    else throw "type ${def.type} not supported";

  # Either value of type `finalType` or `coercedType`, the latter is
  # converted to `finalType` using `coerceFunc`.
  coercedTo = coercedType: coerceFunc: finalType:
    mkOptionType rec {
      name = "coercedTo";
      description = "${finalType.description} or ${coercedType.description}";
      check = x: finalType.check x || coercedType.check x;
      merge = loc: defs:
        let
          coerceVal = val:
            if finalType.check val then val
            else let
              coerced = coerceFunc val;
            in assert finalType.check coerced; coerced;

        in finalType.merge loc (map (def: def // { value = coerceVal def.value; }) defs);
      getSubOptions = finalType.getSubOptions;
      getSubModules = finalType.getSubModules;
      substSubModules = m: coercedTo coercedType coerceFunc (finalType.substSubModules m);
      typeMerge = t1: t2: null;
      functor = (defaultFunctor name) // { wrapped = finalType; };
    };

  submoduleOf = definition: types.submodule { options = definition; };

  refType = attr: head (tail (tail (splitString "/" attr."$ref")));

  extraOptions = {
    nix.dependencies = mkOption {
      description = "List of resources that resource depends on";
      type = types.listOf types.str;
      default = [];
    };
  };

  definitionsForKubernetesSpecs = url: hash:
    let
      swagger = fetchSpecs url hash;
      swaggerDefinitions = swagger.definitions;

      definitions = mapAttrs (name: definition:
        # if $ref is in definition it means it's an alias of other definition
        if hasAttr "$ref" definition
        then definitions."${refType definition}"

        else if !(hasAttr "properties" definition)
        then {}

        # in other case it's an actual definition
        else mapAttrs (propName: property:
          let
            isRequired = elem propName (definition.required or []);
            requiredOrNot = type: if isRequired then type else types.nullOr type;
            optionProperties =
              # if $ref is in property it references other definition,
              # but if other definition does not have properties, then just take it's type
              if hasAttr "$ref" property then
                if hasTypeMapping swaggerDefinitions.${refType property} then {
                  type = requiredOrNot (mapType swaggerDefinitions.${refType property});
                }
                else {
                  type = requiredOrNot (submoduleOf definitions.${refType property});
                }

              # if property has an array type
              else if property.type == "array" then

                # if reference is in items it can reference other type of another
                # definition
                if hasAttr "$ref" property.items then

                  # if it is a reference to simple type
                  if hasTypeMapping swaggerDefinitions.${refType property.items}
                  then {
                    type = requiredOrNot (types.listOf (mapType swaggerDefinitions.${refType property.items}.type));
                  }

                  # if a reference is to complex type
                  else
                    # if x-kubernetes-patch-merge-key is set then make it an
                    # attribute set of submodules
                    if hasAttr "x-kubernetes-patch-merge-key" property
                    then let
                      mergeKey = property."x-kubernetes-patch-merge-key";
                      convertName = name:
                        if definitions.${refType property.items}.${mergeKey}.type == types.int
                        then toInt name
                        else name;
                    in {
                      type = requiredOrNot (coercedTo
                        (types.listOf (submoduleOf definitions.${refType property.items}))
                        (values:
                          listToAttrs (map
                            (value: nameValuePair (toString value.${mergeKey}) value)
                          values)
                        )
                        (types.attrsOf (types.submodule (
                          {name, ...}: {
                            options = definitions.${refType property.items};
                            config.${mergeKey} = mkDefault (convertName name);
                          }
                        ))
                      ));
                      apply = values: if values != null then mapAttrsToList (n: v: v) values else values;
                    }

                    # in other case it's a simple list
                    else {
                      type = requiredOrNot (types.listOf (submoduleOf definitions.${refType property.items}));
                    }

                # in other case it only references a simple type
                else {
                  type = requiredOrNot (types.listOf (mapType property.items));
                }

              else if property.type == "object" && hasAttr "additionalProperties" property
              then
                # if it is a reference to simple type
                if (
                  hasAttr "$ref" property.additionalProperties &&
                  hasTypeMapping swaggerDefinitions.${refType property.additionalProperties}
                ) then {
                  type = requiredOrNot (types.attrsOf (mapType swaggerDefinitions.${refType property.additionalProperties}));
                }

                # if is an array
                else if property.additionalProperties.type == "array"
                then {
                  type = requiredOrNot (types.loaOf (mapType property.additionalProperties.items));
                }

                else {
                  type = requiredOrNot (types.attrsOf (mapType property.additionalProperties));
                }

              else {
                type = requiredOrNot (mapType property);
              };
          in
            mkOption {
              inherit (definition) description;
            } // optionProperties // (optionalAttrs (!isRequired) {
              default = null;
            })
        ) definition.properties
      ) swaggerDefinitions;

      exportedDefinitions =
        zipAttrs (
          mapAttrsToList (name: path: let
            kind = path.post."x-kubernetes-group-version-kind".kind;

            lastChar = substring ((stringLength kind)-1) (stringLength kind) kind;

            suffix =
              if lastChar == "y" then "ies"
              else if hasSuffix "ss" kind then "ses"
              else if lastChar == "s" then "s"
              else "${lastChar}s";

            optionName = "${toLower (substring 0 1 kind)}${substring 1 ((stringLength kind)-2) kind}${suffix}";
          in {
            ${optionName} = refType (head path.post.parameters).schema;
          })
          (filterAttrs (name: path:
            hasAttr "post" path &&
            path.post."x-kubernetes-action" == "post"
          ) swagger.paths)
        );

      kubernetesResourceOptions = mapAttrs (name: value:
      let
        values = if isList value then reverseList value else [value];
        definitionName = tail values;

        submoduleWithDefaultsOf = definition: swaggerDefinition: let
          kind = (head swaggerDefinition."x-kubernetes-group-version-kind").kind;
          group = (head swaggerDefinition."x-kubernetes-group-version-kind").group;
          version = (head swaggerDefinition."x-kubernetes-group-version-kind").version;
          groupVersion = if group != "" then "${group}/${version}" else version;
        in types.submodule ({name, ...}: {
          options = definition // extraOptions;
          config.kind = mkDefault kind;
          config.apiVersion = mkDefault groupVersion;
          config.metadata.name = mkDefault name;
        });

        type =
          if (length values) > 1
          then fold (name: other:
            types.either (submoduleWithDefaultsOf definitions.${name} swaggerDefinitions.${name}) other
          ) (submoduleWithDefaultsOf definitions.${head values} swaggerDefinitions.${head values}) (drop 1 values)
          else submoduleWithDefaultsOf definitions.${head values} swaggerDefinitions.${head values};
      in mkOption {
        description = swaggerDefinitions.${definitionName}.description;
        type = types.attrsOf type;
        default = {};
      }) exportedDefinitions;

      customResourceOptions = mapAttrs (name: crd:
        mkOption {
          type = types.attrsOf (types.submodule ({name, config, ...}: {
            options = {
              apiVersion = mkOption {
                description = "API version of custom resource";
                type = types.str;
                default = "${crd.spec.group}/${crd.spec.version}";
              };

              kind = mkOption {
                description = "Custom resource kind";
                type = types.str;
                default = crd.spec.names.kind;
              };

              metadata = definitions."io.k8s.apimachinery.pkg.apis.meta.v1.ObjectMeta";

              spec = mkOption {
                description = "Custom resource specification";
                type = types.attrs;
                default = {};
              };
            } // extraOptions;

            config.metadata.name = mkDefault name;
          }));
        }
      ) config.kubernetes.resources.customResourceDefinitions;
    in {
      inherit swaggerDefinitions definitions exportedDefinitions kubernetesResourceOptions customResourceOptions;
    };

  versionDefinitions = {
    "1.7" = definitionsForKubernetesSpecs
      "https://github.com/kubernetes/kubernetes/raw/release-1.7/api/openapi-spec/swagger.json"
      "0dazg36g98ynmlzqm17xyha2m411dzvlw3n8bq4fqbnq417wl880";
    "1.8" = definitionsForKubernetesSpecs
      "https://github.com/kubernetes/kubernetes/raw/release-1.8/api/openapi-spec/swagger.json"
      "16ic5gbxnpky9r2vhimn4zaz7cnk1qmkzkayxmn96br3l2s3vkxl";
  };

  versionOptions = {
    "1.7" = (versionDefinitions."1.7").kubernetesResourceOptions // {
      # kubernetes 1.7 supports crd, but does not have swagger definitions for some reason
      customResourceDefinitions =
        versionDefinitions."1.8".kubernetesResourceOptions.customResourceDefinitions;
    };
    "1.8" = (versionDefinitions."1.8").kubernetesResourceOptions;
  };
in {
  options.kubernetes.version = mkOption {
    description = "Kubernetes version to deploy to";
    type = types.enum (attrNames versionDefinitions);
    default = "1.7";
  };

  options.kubernetes.resources = mkOption {
    type = types.submodule {
      options = versionOptions.${config.kubernetes.version};
    };
    description = "Attribute set of kubernetes resources";
    default = {};
  };

  options.kubernetes.customResources = mkOption {
    type = types.submodule {
      options = versionDefinitions.${config.kubernetes.version}.customResourceOptions;
    };
    description = "Attribute set of custom kubernetes resources";
    default = {};
  };
}
