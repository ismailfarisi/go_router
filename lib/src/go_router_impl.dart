import 'package:flutter/widgets.dart';
import 'package:path_to_regexp/path_to_regexp.dart' as p2re;

import '../go_router.dart';

typedef GoRouterBuilderWithMatches = Widget Function(
  BuildContext context,
  Iterable<GoRouteMatch> matches,
);

typedef GoRouterBuilderWithNav = Widget Function(
  BuildContext context,
  Navigator navigator,
);

/// GoRouter implementation of the RouterDelegate base class
class GoRouterDelegate extends RouterDelegate<Uri>
    with
        PopNavigatorRouterDelegateMixin<Uri>,
        // ignore: prefer_mixin
        ChangeNotifier {
  final GoRouterBuilderWithNav builderWithNav;
  final List<GoRoute> routes;
  final GoRouterRedirect topRedirect;
  final Listenable? refreshListenable;
  final GoRouterPageBuilder errorBuilder;

  final _key = GlobalKey<NavigatorState>();
  final List<GoRouteMatch> _matches = [];

  GoRouterDelegate({
    required this.builderWithNav,
    required this.routes,
    required this.errorBuilder,
    GoRouterRedirect? topRedirect,
    this.refreshListenable,
    Uri? initUri,
    bool debugOutputFullPaths = false,
  }) : topRedirect = topRedirect ?? _redirect {
    // check that the route paths are valid
    for (final route in routes) {
      if (!route.path.startsWith('/')) {
        throw Exception('top-level path must start with "/": ${route.path}');
      }
    }

    // output known routes
    if (debugOutputFullPaths) _outputFullPaths();

    // build the list of route matches
    _go((initUri ?? Uri()).toString());

    // when the listener changes, refresh the route
    refreshListenable?.addListener(refresh);
  }

  void go(String location) {
    _go(location);
    notifyListeners();
  }

  void refresh() {
    _go(_matches.last.subloc);
    notifyListeners();
  }

  String get location => _matches.last.subloc;

  void _pop() => _matches.remove(_matches.last);

  @override
  void dispose() {
    refreshListenable?.removeListener(refresh);
    super.dispose();
  }

  @override
  GlobalKey<NavigatorState> get navigatorKey => _key;

  @override
  Uri get currentConfiguration => Uri.parse(location);

  @override
  Widget build(BuildContext context) => _builder(context, _matches);

  @override
  Future<void> setInitialRoutePath(Uri configuration) async {
    // if the initial location is /, then use the dev initial location;
    // otherwise, we're cruising to a deep link, so ignore dev initial location
    final config = configuration.toString();
    _go(config == '/' ? location : config);
  }

  @override
  Future<void> setNewRoutePath(Uri configuration) async =>
      _go(configuration.toString());

  static String? _redirect(String location) => null;

  void _go(String location) {
    assert(Uri.tryParse(location) != null);

    // watch redirects for loops
    var loc = location;
    final redirects = List<String>.filled(1, loc, growable: true);
    bool redirected(String? redir) {
      if (redir == null) return false;

      if (redirects.contains(redir)) {
        redirects.add(redir);
        final msg = 'Redirect loop detected: ${redirects.join(' => ')}';
        throw Exception(msg);
      }

      redirects.add(redir);
      loc = redir;
      return true;
    }

    // keep looping till we're done redirecting
    for (;;) {
      // check for top-level redirect
      if (redirected(topRedirect(loc))) continue;

      // get stack of route matches
      final matches = getLocRouteMatches(loc);

      // check top route for redirect
      if (redirected(matches.last.route.redirect(loc))) continue;

      // no more redirects!
      _matches.clear();
      _matches.addAll(matches);
      break;
    }
  }

  /// Call _getLocRouteMatchStacks and check for errors
  @visibleForTesting
  List<GoRouteMatch> getLocRouteMatches(String location) {
    final loc = Uri.parse(location).path;
    final matchStacks = _getLocRouteMatchStacks(
      loc: loc,
      restLoc: loc,
      routes: routes,
      parentFullpath: '',
      parentSubloc: '',
    ).toList();

    if (matchStacks.isEmpty) {
      throw Exception('no routes for location: $loc');
    }

    if (matchStacks.length > 1) {
      final sb = StringBuffer();
      sb.writeln('too many routes for location: $loc');

      for (final stack in matchStacks) {
        sb.writeln('\t${stack.map((m) => m.route.path).join(' => ')}');
      }

      throw Exception(sb.toString());
    }

    assert(matchStacks.length == 1);
    assert(matchStacks.first.last.subloc.toLowerCase() == loc.toLowerCase());
    return matchStacks.first;
  }

  /// turns a list of routes into a list of routes match stacks for the location
  /// e.g. routes: [
  ///   /
  ///     family/:fid
  ///   /login
  /// ]
  ///
  /// loc: /
  /// stacks: [
  ///   matches: [
  ///     match(route.path=/, loc=/)
  ///   ]
  /// ]
  ///
  /// loc: /login
  /// stacks: [
  ///   matches: [
  ///     match(route.path=/login, loc=login)
  ///   ]
  /// ]
  ///
  /// loc: /family/f2
  /// stacks: [
  ///   matches: [
  ///     match(route.path=/, loc=/),
  ///     match(route.path=family/:fid, loc=family/f2, params=[fid=f2])
  ///   ]
  /// ]
  ///
  /// loc: /family/f2/person/p1
  /// stacks: [
  ///   matches: [
  ///     match(route.path=/, loc=/),
  ///     match(route.path=family/:fid, loc=family/f2, params=[fid=f2])
  ///     match(route.path=person/:pid, loc=person/p1, params=[fid=f2, pid=p1])
  ///   ]
  /// ]
  ///
  /// A stack count of 0 means there's no match.
  /// A stack count of >1 means there's a malformed set of routes.
  ///
  /// NOTE: Uses recursion, which is why _getLocRouteMatchStacks calls this
  /// function and does the actual error checking, using the returned stacks to
  /// provide better errors
  static Iterable<List<GoRouteMatch>> _getLocRouteMatchStacks({
    required String loc,
    required String restLoc,
    required String parentSubloc,
    required List<GoRoute> routes,
    required String parentFullpath,
  }) sync* {
    // assume somebody else has removed the query params
    assert(Uri.parse(restLoc).path == restLoc);

    // find the set of matches at this level of the tree
    for (final route in routes) {
      final fullpath = _fullLocFor(parentFullpath, route.path);
      final match = GoRouteMatch.match(
        route: route,
        restLoc: restLoc,
        parentSubloc: parentSubloc,
        path: route.path,
        fullpath: fullpath,
      );
      if (match == null) continue;

      // if we have a complete match, then return the matched route
      if (match.subloc == loc) {
        yield [match];
        continue;
      }

      // if we have a partial match but no sub-routes, bail
      if (route.routes.isEmpty) continue;

      // otherwise recurse
      final childRestLoc =
          loc.substring(match.subloc.length + (match.subloc == '/' ? 0 : 1));
      assert(loc.startsWith(match.subloc));
      assert(restLoc.isNotEmpty);

      // if there's no sub-route matches, then we don't have a match for this
      // location
      final subRouteMatchStacks = _getLocRouteMatchStacks(
        loc: loc,
        restLoc: childRestLoc,
        parentSubloc: match.subloc,
        routes: route.routes,
        parentFullpath: fullpath,
      ).toList();
      if (subRouteMatchStacks.isEmpty) continue;

      // add the match to each of the sub-route match stacks and return them
      for (final stack in subRouteMatchStacks) yield [match, ...stack];
    }
  }

  // e.g.
  // parentFullLoc: '',          path =>                  '/'
  // parentFullLoc: '/',         path => 'family/:fid' => '/family/:fid'
  // parentFullLoc: '/',         path => 'family/f2' =>   '/family/f2'
  // parentFullLoc: '/famiy/f2', path => 'parent/p1' =>   '/family/f2/person/p1'
  static String _fullLocFor(String parentFullLoc, String path) {
    // at the root, just return the path
    if (parentFullLoc.isEmpty) {
      assert(path.startsWith('/'));
      assert(path == '/' || !path.endsWith('/'));
      return path;
    }

    // not at the root, so append the parent path
    assert(path.isNotEmpty);
    assert(!path.startsWith('/'));
    assert(!path.endsWith('/'));
    return '${parentFullLoc == '/' ? '' : parentFullLoc}/$path';
  }

  Widget _builder(BuildContext context, Iterable<GoRouteMatch> matches) {
    final pages = <Page<dynamic>>[];

    try {
      // build the stack of pages
      final routePages = getPages(context, matches);
      pages.addAll(routePages);
    } on Exception catch (ex) {
      // if there's an error, show an error page
      final errorPage = errorBuilder(
        context,
        GoRouterState(
          location: location,
          subloc: location,
          error: ex,
        ),
      );
      pages.add(errorPage);
    }

    // wrap the returned Navigator to enable GoRouter.of(context).go()
    return builderWithNav(
      context,
      Navigator(
        pages: pages,
        onPopPage: (route, dynamic result) {
          if (!route.didPop(result)) return false;
          _pop();
          return true;
        },
      ),
    );
  }

  /// get the stack of sub-routes that matches the location and turn it into a
  /// stack of pages, e.g.
  /// routes: [
  ///   /
  ///     family/:fid
  ///       person/:pid
  ///   /login
  /// ]
  ///
  /// loc: /
  /// pages: [ HomePage()]
  ///
  /// loc: /login
  /// pages: [ LoginPage() ]
  ///
  /// loc: /family/f2
  /// pages: [  HomePage(), FamilyPage(f2) ]
  ///
  /// loc: /family/f2/person/p1
  /// pages: [ HomePage(), FamilyPage(f2), PersonPage(f2, p1) ]
  @visibleForTesting
  List<Page<dynamic>> getPages(
    BuildContext context,
    Iterable<GoRouteMatch> matches,
  ) {
    final pages = <Page<dynamic>>[];
    final uri = Uri.parse(matches.last.subloc);
    var params = uri.queryParameters; // start w/ the query parameters
    for (final match in matches) {
      // merge new params, overriding old ones, i.e. path params override
      // query parameters, sub-location params override top level params, etc.
      // this also keeps params from previously matched paths, e.g.
      // /family/:fid/person/:pid provides fid and pid to person/:pid
      params = {...params, ...match.params};

      // get a page from the builder and associate it with a sub-location
      final page = match.route.builder(
        context,
        GoRouterState(
          location: location,
          subloc: match.subloc,
          path: match.route.path,
          fullpath: match.fullpath,
          params: params,
        ),
      );
      pages.add(page);
    }

    assert(pages.isNotEmpty);
    return pages;
  }

  void _outputFullPaths() {
    // ignore: avoid_print
    print('');
    // ignore: avoid_print
    print('GoRouter: full paths');
    _outputFullPathsFor(routes, '', 0);
    // ignore: avoid_print
    print('');
  }

  void _outputFullPathsFor(
    List<GoRoute> routes,
    String parentFullpath,
    int depth,
  ) {
    for (final route in routes) {
      final fullpath = _fullLocFor(parentFullpath, route.path);
      // ignore: avoid_print
      print('${''.padLeft(depth * 2)}$fullpath');
      _outputFullPathsFor(route.routes, fullpath, depth + 1);
    }
  }
}

/// GoRouter implementation of the RouteInformationParser base class
class GoRouteInformationParser extends RouteInformationParser<Uri> {
  @override
  Future<Uri> parseRouteInformation(RouteInformation routeInformation) async =>
      Uri.parse(routeInformation.location!);

  @override
  RouteInformation restoreRouteInformation(Uri configuration) =>
      RouteInformation(location: configuration.toString());
}

/// GoRouter implementation of InheritedWidget for purposes of finding the
/// current GoRouter in the widget tree. This is useful when routing from
/// anywhere in your app.
class InheritedGoRouter extends InheritedWidget {
  final GoRouter goRouter;
  const InheritedGoRouter({
    required Widget child,
    required this.goRouter,
    Key? key,
  }) : super(child: child, key: key);

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => true;
}

class GoRouteMatch {
  final GoRoute route;
  final String subloc;
  final String fullpath;
  final Map<String, String> params;
  GoRouteMatch({
    required this.route,
    required this.subloc,
    required this.fullpath,
    required this.params,
  })  : assert(subloc.startsWith('/')),
        assert(fullpath.startsWith('/'));

  static GoRouteMatch? match({
    required GoRoute route,
    required String restLoc,
    required String parentSubloc,
    required String path,
    required String fullpath,
  }) {
    assert(!path.contains('//'));

    final match = route.matchPatternAsPrefix(restLoc);
    if (match == null) return null;

    final params = route.extractPatternParams(match);
    final pathLoc = _locationFor(path, params);
    final subloc = GoRouterDelegate._fullLocFor(parentSubloc, pathLoc);
    return GoRouteMatch(
      route: route,
      subloc: subloc,
      fullpath: fullpath,
      params: params,
    );
  }

  /// expand a path w/ param slots using params, e.g. family/:fid => family/f1
  static String _locationFor(String path, Map<String, String> params) =>
      p2re.pathToFunction(path)(params);
}
