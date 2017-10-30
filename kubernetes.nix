{ config, lib, k8s, pkgs, ... }:

with lib;

let
  fixJSON = content: replaceStrings ["\\u"] ["u"] content;

  fetchSpecs = url: sha256:
    builtins.fromJSON (fixJSON (builtins.readFile (pkgs.fetchurl { inherit url sha256; })));

  swaggerSpecs = {
    "1.7" = fetchSpecs
      "https://github.com/kubernetes/kubernetes/raw/release-1.7/api/openapi-spec/swagger.json"
      "0dazg36g98ynmlzqm17xyha2m411dzvlw3n8bq4fqbnq417wl880";

    "1.8" = fetchSpecs
      "https://github.com/kubernetes/kubernetes/raw/release-1.8/api/openapi-spec/swagger.json"
      "16ic5gbxnpky9r2vhimn4zaz7cnk1qmkzkayxmn96br3l2s3vkxl";
  };

  swagger = swaggerSpecs.${config.kubernetes.version};
  swaggerDefinitions = swagger.definitions;

  typeMappings = {
    string = types.str;
    integer = types.int;
    boolean = types.bool;
    object = types.attrs;
  };

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

  definitions = mapAttrs (name: definition:
  let
  in
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
            if (
              hasAttr "type" swaggerDefinitions.${refType property} &&
              hasAttr swaggerDefinitions.${refType property}.type typeMappings
            ) then {
              type = requiredOrNot (typeMappings.${swaggerDefinitions.${refType property}.type});
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
              if (
                hasAttr "type" swaggerDefinitions.${refType property.items} &&
                hasAttr swaggerDefinitions.${refType property.items}.type typeMappings
              ) then {
                type = requiredOrNot (types.listOf typeMappings.${swaggerDefinitions.${refType property.items}.type});
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
              type = requiredOrNot (types.listOf typeMappings.${property.items.type});
            }

          else if property.type == "object" && hasAttr "additionalProperties" property
          then
            # if it is a reference to simple type
            if (
              hasAttr "$ref" property.additionalProperties &&
              hasAttr "type" swaggerDefinitions.${refType property.additionalProperties} &&
              hasAttr swaggerDefinitions.${refType property.additionalProperties}.type typeMappings
            ) then {
              type = requiredOrNot (types.attrsOf typeMappings.${swaggerDefinitions.${refType property.additionalProperties}.type});
            }

            # if is an array
            else if property.additionalProperties.type == "array"
            then {
              type = requiredOrNot (types.loaOf typeMappings.${property.additionalProperties.items.type});
            }

            else {
              type = requiredOrNot (types.attrsOf typeMappings.${property.additionalProperties.type});
            }

          else {
            type = requiredOrNot (typeMappings.${property.type});
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
      options = definition;
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
        };

        config.metadata.name = mkDefault name;
      }));
    }
  ) config.kubernetes.resources.customResourceDefinitions;
in {
  options.kubernetes.version = mkOption {
    description = "Kubernetes version to deploy to";
    type = types.enum (attrNames swaggerSpecs);
    default = "1.7";
  };

  options.kubernetes.resources = mkOption {
    type = types.submodule {
      options = kubernetesResourceOptions;
    };
    description = "Attribute set of kubernetes resources";
    default = {};
  };

  options.kubernetes.customResources = mkOption {
    type = types.submodule {
      options = customResourceOptions;
    };
    description = "Attribute set of custom kubernetes resources";
    default = {};
  };
}
